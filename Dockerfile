FROM ubuntu:22.04 AS compiler-common
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  git-core \
  ca-certificates
# && apt-get update

###########################################################################################################

FROM compiler-common AS compiler-stylesheet
RUN cd ~ \
  && git clone --depth 1 https://github.com/gravitystorm/openstreetmap-carto.git \
  && cd openstreetmap-carto \
  && sed -i 's/, "unifont Medium", "Unifont Upper Medium"//g' style/fonts.mss \
  && sed -i 's/"Noto Sans Tibetan Regular",//g' style/fonts.mss \
  && sed -i 's/"Noto Sans Tibetan Bold",//g' style/fonts.mss \
  && sed -i 's/Noto Sans Syriac Eastern Regular/Noto Sans Syriac Regular/g' style/fonts.mss \
  && rm -rf .git

###########################################################################################################

FROM compiler-common AS compiler-helper-script
RUN cd ~ \
  && git clone --depth 1 https://github.com/zverik/regional \
  && cd regional \
  && chmod u+x trim_osc.py \
  && rm -rf .git

###########################################################################################################

FROM compiler-common AS compiler-osm2pgsql
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  make \
  cmake \
  g++ \
  libboost-dev \
  libboost-system-dev \
  libboost-filesystem-dev \
  libexpat1-dev \
  zlib1g-dev \
  libbz2-dev \
  libpq-dev \
  libproj-dev \
  lua5.3 \
  liblua5.3-dev \
  pandoc

RUN cd ~ \
  && git clone --depth 1 https://github.com/openstreetmap/osm2pgsql \
  && cd osm2pgsql \
  && mkdir -p build \
  && cd build \
  && cmake .. \
  && make \
  && make install \
  && rm -rf .git

###########################################################################################################


FROM ubuntu:22.04 AS final

# Based on https://switch2osm.org/serving-tiles/manually-building-a-tile-server-18-04-lts/

ENV DEBIAN_FRONTEND=noninteractive
# ENV AUTOVACUUM=off
ENV UPDATES=disabled
ENV REPLICATION_URL=https://planet.openstreetmap.org/replication/hour/
ENV MAX_INTERVAL_SECONDS=3600
ENV THREADS=8

ARG TZ=America/Montreal
ARG USER=tirex

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone


RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  sudo \
  curl \
  wget \
  ca-certificates


# Add postgresql-15 repository
RUN echo "deb http://apt.postgresql.org/pub/repos/apt jammy-pgdg main" > /etc/apt/sources.list.d/pgdg.list
RUN wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc

# Get packages
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  apache2 \
  cron \
  curl \
  dateutils \
  fonts-hanazono \
  fonts-noto-cjk \
  fonts-noto-hinted \
  fonts-noto-unhinted \
  fonts-unifont \
  gdal-bin \
  liblua5.3-dev \
  lua5.3 \
  mapnik-utils \
  nano \
  npm \
  osmium-tool \
  osmosis \
  postgresql-15 \
  postgresql-client-15 \
  postgresql-15-postgis-3 \
  postgresql-15-postgis-3-scripts \
  postgis \
  python-is-python3 \
  python3-mapnik \
  python3-lxml \
  python3-psycopg2 \
  python3-shapely \
  python3-pip \
  tirex \
  tirex-example-map \
  systemctl \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/


# RUN adduser --disabled-password --gecos "" tirex

# Get Noto Emoji Regular font, despite it being deprecated by Google
RUN wget https://github.com/googlefonts/noto-emoji/blob/9a5261d871451f9b5183c93483cbd68ed916b1e9/fonts/NotoEmoji-Regular.ttf?raw=true --content-disposition -P /usr/share/fonts/

# For some reason this one is missing in the default packages
RUN wget https://github.com/stamen/terrain-classic/blob/master/fonts/unifont-Medium.ttf?raw=true --content-disposition -P /usr/share/fonts/

# Install python libraries
RUN pip3 install \
  requests \
  osmium \
  pyyaml

# Install carto for stylesheet
RUN npm install -g carto

RUN 


# # Configure Apache
# RUN echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf \
#   && echo "LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so" >> /etc/apache2/conf-available/mod_headers.conf \
#   && a2enconf mod_tile && a2enconf mod_headers
# COPY apache.conf /etc/apache2/sites-available/000-default.conf
# RUN ln -sf /dev/stdout /var/log/apache2/access.log \
#   && ln -sf /dev/stderr /var/log/apache2/error.log

# # leaflet
# COPY leaflet-demo.html /var/www/html/index.html
# RUN cd /var/www/html/ \
#   && wget https://github.com/Leaflet/Leaflet/releases/download/v1.8.0/leaflet.zip \
#   && unzip leaflet.zip \
#   && rm leaflet.zip

# # Icon
# RUN wget -O /var/www/html/favicon.ico https://www.openstreetmap.org/favicon.ico

# # Copy update scripts
# #COPY openstreetmap-tiles-update-expire.sh /usr/bin/
# #RUN chmod +x /usr/bin/openstreetmap-tiles-update-expire.sh \
# #  && mkdir -p /var/log/tiles \
# # && chmod a+rw /var/log/tiles \
# # && ln -s /home/_renderd/src/mod_tile/osmosis-db_replag /usr/bin/osmosis-db_replag \
# #  && echo "* * * * *   _renderd    openstreetmap-tiles-update-expire.sh\n" >> /etc/crontab

# Configure PosgtreSQL
# COPY postgresql.custom.conf.tmpl /etc/postgresql/15/main/
# RUN chown -R postgres: /var/lib/postgresql \
#   && chown postgres: /etc/postgresql/15/main/postgresql.custom.conf.tmpl
#   && echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/15/main/pg_hba.conf \
#   && echo "host all all ::/0 md5" >> /etc/postgresql/15/main/pg_hba.conf

# Create volume directories
RUN mkdir -p /run/tirex/ \
  && mkdir -p /home/_tirex/src/ \
  && mkdir -p /data/database/ \
  && mkdir -p /data/style/ \
  && mkdir -p /data/config \
  && mv /var/lib/postgresql/15/main/ /data/database/postgres/ \
  && mv /var/cache/tirex/tiles/ /data/tiles/ \
  && chown -R _tirex: /run/tirex/ \
  && chown -R _tirex: /home/_tirex/ \
  && ln -s /data/database/postgres /var/lib/postgresql/15/main \
  && ln -s /data/style /home/_tirex/src/openstreetmap-carto \
  && ln -s /data/tiles /var/cache/tirex/tiles \
  ;

# Configure PosgtreSQL
COPY postgresql.custom.conf /data/config
RUN chown -R postgres: /var/lib/postgresql \
  && chown -R postgres: /data/config
#   && echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/15/main/pg_hba.conf \
#   && echo "host all all ::/0 md5" >> /etc/postgresql/15/main/pg_hba.conf

# Configure Tirex
COPY tirex-region.conf /data/config

# Install helper scripts
COPY --from=compiler-helper-script /root/regional /home/_tirex/src/regional
COPY --from=compiler-stylesheet /root/openstreetmap-carto /home/_tirex/src/openstreetmap-carto-backup
# COPY --from=compiler-osm2pgsql /root/osm2pgsql /home/_tirex/src/osm2pgsql
COPY --from=compiler-osm2pgsql /root/osm2pgsql/build/osm2pgsql /usr/local/bin/osm2pgsql
COPY --from=compiler-osm2pgsql /root/osm2pgsql/scripts/osm2pgsql-replication /usr/local/bin/osm2pgsql-replication


# Start running
COPY run.sh /
ENTRYPOINT ["/run.sh"]
CMD []
#EXPOSE 8080 5432
EXPOSE 8083
