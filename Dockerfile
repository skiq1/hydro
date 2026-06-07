FROM ruby:3.4-slim

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential libsqlite3-dev sqlite3 \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

COPY . .

RUN mkdir -p data public/uploads

ENV RACK_ENV=production
ENV PORT=4567
ENV DATABASE_PATH=/app/data/hydro.sqlite3

EXPOSE 4567

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
