threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads threads_count, threads_count

rackup "config.ru"
port ENV.fetch("PORT", 4567)
environment ENV.fetch("RACK_ENV", "production")
