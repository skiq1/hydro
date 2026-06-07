## Uruchomienie lokalne

```bash
bundle install
bundle exec puma -C puma.rb
```

Aplikacja będzie dostępna pod adresem:

```text
http://localhost:4567
```

## Uruchomienie przez Docker Compose

```bash
docker compose up -d --build
```

Aplikacja jest wystawiana przez Traefika pod domeną:

```text
https://hydro.dqq.pl
```

Compose zakłada wspólną zewnętrzną sieć Dockera o nazwie `proxy`. Utwórz ją raz na serwerze:

```bash
docker network create proxy
```

Kontener Traefika z osobnego `compose.yml` musi być podłączony do tej samej sieci. Jeśli Twoja sieć Traefika ma inną nazwę, zmień ją w `compose.yml` w sekcji `networks` oraz w labelu `traefik.docker.network`.

## Eksport do QGIS

- `http://localhost:4567/export.geojson` - warstwa punktowa GeoJSON.
- `http://localhost:4567/export.csv` - tabela CSV z `latitude` i `longitude`.

W QGIS najprościej dodać GeoJSON jako warstwę wektorową. CSV też działa, ale trzeba wskazać pole X jako `longitude`, a Y jako `latitude`, układ `EPSG:4326`.

## Dane trwałe

W Docker Compose baza SQLite i zdjęcia są trzymane w lokalnych katalogach projektu:

- `./data`
- `./public/uploads`

Poza Dockerem baza domyślnie trafia do `data/hydro.sqlite3`, a zdjęcia do `public/uploads`.
