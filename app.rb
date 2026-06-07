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
        photo_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL
    database.execute("CREATE INDEX IF NOT EXISTS idx_observations_created_at ON observations(created_at)")
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

    def photo_url(path)
      path && !path.empty? ? path : nil
    end
  end

  before do
    cache_control :no_store if request.path_info.start_with?("/observations")
  end

  get "/" do
    erb :new
  end

  get "/observations" do
    @observations = db.execute(<<~SQL)
      SELECT * FROM observations
      ORDER BY datetime(created_at) DESC, id DESC
    SQL
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

    @form_values = {
      "name" => name,
      "description" => description,
      "latitude" => params[:latitude],
      "longitude" => params[:longitude],
      "accuracy" => params[:accuracy]
    }

    @errors = []
    @errors << "Podaj nazwę punktu." if name.empty?
    @errors << "Zaznacz lokalizację na mapie albo użyj GPS." unless latitude && longitude
    @errors << "Szerokość geograficzna jest poza zakresem." if latitude && !latitude.between?(-90, 90)
    @errors << "Długość geograficzna jest poza zakresem." if longitude && !longitude.between?(-180, 180)

    if @errors.any?
      status 422
      return erb :new
    end

    stored_photo = store_photo(params[:photo])
    now = Time.now.utc.iso8601

    db.execute(<<~SQL, [name, description, latitude, longitude, accuracy, stored_photo, now, now])
      INSERT INTO observations
        (name, description, latitude, longitude, accuracy, photo_path, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    redirect "/observations/#{db.last_insert_row_id}?created=1"
  end

  get "/export.csv" do
    content_type "text/csv; charset=utf-8"
    attachment "hydro-observations.csv"

    rows = all_observations
    CSV.generate(headers: true) do |csv|
      csv << %w[id name description latitude longitude accuracy photo_url created_at updated_at]
      rows.each do |row|
        csv << [
          row["id"],
          row["name"],
          row["description"],
          row["latitude"],
          row["longitude"],
          row["accuracy"],
          absolute_photo_url(row),
          row["created_at"],
          row["updated_at"]
        ]
      end
    end
  end

  get "/export.geojson" do
    content_type :json
    rows = all_observations

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
            name: row["name"],
            description: row["description"],
            accuracy: row["accuracy"],
            photo_url: absolute_photo_url(row),
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

  def all_observations
    db.execute("SELECT * FROM observations ORDER BY datetime(created_at) DESC, id DESC")
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

  def store_photo(upload)
    return nil unless upload && upload[:tempfile] && upload[:filename]

    extension = File.extname(upload[:filename].to_s.downcase)
    extension = ".jpg" if extension.empty?
    allowed_extensions = %w[.jpg .jpeg .png .webp .gif .heic .heif]
    halt 422, "Nieobsługiwany format zdjęcia." unless allowed_extensions.include?(extension)

    filename = "#{SecureRandom.uuid}#{extension}"
    destination = File.join(UPLOAD_DIR, filename)
    FileUtils.cp(upload[:tempfile].path, destination)
    "/uploads/#{filename}"
  end

  def absolute_photo_url(row)
    return nil unless row["photo_path"] && !row["photo_path"].empty?

    uri(row["photo_path"], true)
  end
end
