require "csv"
require "fileutils"
require "json"
require "securerandom"
require "sqlite3"
require "sinatra/base"
require "time"

class HydroApp < Sinatra::Base
  DB_PATH = ENV.fetch("DATABASE_PATH", File.expand_path("data/hydro.sqlite3", __dir__))
  UPLOAD_DIR = File.expand_path("public/uploads", __dir__)

  def self.database
    @database ||= SQLite3::Database.new(DB_PATH).tap do |connection|
      connection.results_as_hash = true
      connection.execute("PRAGMA foreign_keys = ON")
      connection.execute("PRAGMA journal_mode = WAL")
    end
  end

  def self.initialize_database
    database.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS observations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        accuracy REAL,
        group_number INTEGER NOT NULL DEFAULT 1,
        photo_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL
    add_group_column unless column_exists?("observations", "group_number")
    database.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS observation_photos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        observation_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (observation_id) REFERENCES observations(id) ON DELETE CASCADE
      )
    SQL
    database.execute("CREATE INDEX IF NOT EXISTS idx_observations_created_at ON observations(created_at)")
    database.execute("CREATE INDEX IF NOT EXISTS idx_observation_photos_observation_id ON observation_photos(observation_id)")
    migrate_existing_photos
  end

  def self.column_exists?(table_name, column_name)
    database.execute("PRAGMA table_info(#{table_name})").any? do |column|
      column["name"] == column_name
    end
  end

  def self.add_group_column
    database.execute("ALTER TABLE observations ADD COLUMN group_number INTEGER NOT NULL DEFAULT 1")
  end

  def self.migrate_existing_photos
    database.execute(<<~SQL)
      INSERT INTO observation_photos (observation_id, path, created_at)
      SELECT observations.id, observations.photo_path, observations.created_at
      FROM observations
      LEFT JOIN observation_photos
        ON observation_photos.observation_id = observations.id
        AND observation_photos.path = observations.photo_path
      WHERE observations.photo_path IS NOT NULL
        AND observations.photo_path != ''
        AND observation_photos.id IS NULL
    SQL
  end

  configure do
    set :bind, "0.0.0.0"
    set :port, ENV.fetch("PORT", 4567)
    set :public_folder, File.expand_path("public", __dir__)
    set :views, File.expand_path("views", __dir__)
    enable :method_override

    FileUtils.mkdir_p(File.dirname(DB_PATH))
    FileUtils.mkdir_p(UPLOAD_DIR)
    initialize_database
  end

  helpers do
    def db
      self.class.database
    end

    def h(text)
      Rack::Utils.escape_html(text)
    end

    def format_time(value)
      Time.parse(value).strftime("%Y-%m-%d %H:%M") if value
    rescue ArgumentError
      value
    end

    def osm_link(observation)
      "https://www.openstreetmap.org/?mlat=#{observation["latitude"]}&mlon=#{observation["longitude"]}#map=18/#{observation["latitude"]}/#{observation["longitude"]}"
    end

    def photos_for_observation(observation_id)
      db.execute(
        "SELECT * FROM observation_photos WHERE observation_id = ? ORDER BY id ASC",
        observation_id
      )
    end

    def primary_photo_url(observation_id)
      photos_for_observation(observation_id).first&.dig("path")
    end
  end

  before do
    cache_control :no_store if request.path_info.start_with?("/observations")
  end

  get "/" do
    @selected_group = group_param(params[:group_number]) || group_param(request.cookies["hydro_group_number"]) || 1
    erb :new
  end

  get "/observations" do
    @group_filter = group_param(params[:group])
    @observations = all_observations(@group_filter)
    erb :index
  end

  get "/observations/:id" do
    @observation = find_observation(params[:id])
    halt 404, erb(:not_found) unless @observation
    erb :show
  end

  post "/observations" do
    name = params[:name].to_s.strip
    description = params[:description].to_s.strip
    latitude = decimal_param(params[:latitude])
    longitude = decimal_param(params[:longitude])
    accuracy = decimal_param(params[:accuracy])
    group_number = group_param(params[:group_number]) || 1

    @form_values = {
      "name" => name,
      "description" => description,
      "latitude" => params[:latitude],
      "longitude" => params[:longitude],
      "accuracy" => params[:accuracy],
      "group_number" => group_number
    }
    @selected_group = group_number

    @errors = []
    @errors << "Podaj nazwę punktu." if name.empty?
    @errors << "Zaznacz lokalizację na mapie albo użyj GPS." unless latitude && longitude
    @errors << "Szerokość geograficzna jest poza zakresem." if latitude && !latitude.between?(-90, 90)
    @errors << "Długość geograficzna jest poza zakresem." if longitude && !longitude.between?(-180, 180)

    if @errors.any?
      status 422
      return erb :new
    end

    stored_photos = store_photos(params[:photos] || params[:photo])
    now = Time.now.utc.iso8601

    db.execute(<<~SQL, [name, description, latitude, longitude, accuracy, group_number, stored_photos.first, now, now])
      INSERT INTO observations
        (name, description, latitude, longitude, accuracy, group_number, photo_path, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    observation_id = db.last_insert_row_id
    stored_photos.each do |path|
      db.execute(
        "INSERT INTO observation_photos (observation_id, path, created_at) VALUES (?, ?, ?)",
        [observation_id, path, now]
      )
    end

    response.set_cookie(
      "hydro_group_number",
      value: group_number.to_s,
      path: "/",
      max_age: 60 * 60 * 24 * 180,
      same_site: :lax
    )

    redirect "/observations/#{observation_id}?created=1"
  end

  get "/export.csv" do
    content_type "text/csv; charset=utf-8"
    attachment "hydro-observations.csv"

    rows = all_observations(group_param(params[:group]))
    CSV.generate(headers: true) do |csv|
      csv << %w[id group_number name description latitude longitude accuracy photo_urls created_at updated_at]
      rows.each do |row|
        csv << [
          row["id"],
          row["group_number"],
          row["name"],
          row["description"],
          row["latitude"],
          row["longitude"],
          row["accuracy"],
          absolute_photo_urls(row["id"]).join(" | "),
          row["created_at"],
          row["updated_at"]
        ]
      end
    end
  end

  get "/export.geojson" do
    content_type :json
    rows = all_observations(group_param(params[:group]))

    JSON.pretty_generate(
      type: "FeatureCollection",
      features: rows.map do |row|
        {
          type: "Feature",
          geometry: {
            type: "Point",
            coordinates: [row["longitude"].to_f, row["latitude"].to_f]
          },
          properties: {
            id: row["id"],
            group_number: row["group_number"],
            name: row["name"],
            description: row["description"],
            accuracy: row["accuracy"],
            photo_url: absolute_photo_urls(row["id"]).first,
            photo_urls: absolute_photo_urls(row["id"]),
            created_at: row["created_at"],
            updated_at: row["updated_at"]
          }
        }
      end
    )
  end

  not_found do
    erb :not_found
  end

  private

  def all_observations(group_filter = nil)
    if group_filter
      db.execute(
        "SELECT * FROM observations WHERE group_number = ? ORDER BY datetime(created_at) DESC, id DESC",
        group_filter
      )
    else
      db.execute("SELECT * FROM observations ORDER BY datetime(created_at) DESC, id DESC")
    end
  end

  def find_observation(id)
    db.get_first_row("SELECT * FROM observations WHERE id = ? LIMIT 1", id.to_i)
  end

  def decimal_param(value)
    text = value.to_s.strip.tr(",", ".")
    return nil if text.empty?

    Float(text)
  rescue ArgumentError
    nil
  end

  def group_param(value)
    number = value.to_i
    [1, 2].include?(number) ? number : nil
  end

  def store_photos(uploads)
    upload_list = uploads.is_a?(Hash) ? [uploads] : Array(uploads)
    upload_list.filter_map do |upload|
      store_photo(upload)
    end
  end

  def store_photo(upload)
    return nil unless upload && upload[:tempfile] && upload[:filename] && !upload[:filename].to_s.empty?

    extension = File.extname(upload[:filename].to_s.downcase)
    extension = ".jpg" if extension.empty?
    allowed_extensions = %w[.jpg .jpeg .png .webp .gif .heic .heif]
    halt 422, "Nieobsługiwany format zdjęcia." unless allowed_extensions.include?(extension)

    filename = "#{SecureRandom.uuid}#{extension}"
    destination = File.join(UPLOAD_DIR, filename)
    FileUtils.cp(upload[:tempfile].path, destination)
    "/uploads/#{filename}"
  end

  def absolute_photo_urls(observation_id)
    photos_for_observation(observation_id).map do |photo|
      uri(photo["path"], true)
    end
  end
end
