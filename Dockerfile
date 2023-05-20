FROM ubuntu:22.04 AS compiler-common
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  git-core \
  ca-certificates

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
ENV USER=_tirex
ENV POSTGRESQL_VER=15
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

ARG TZ=America/Montreal

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates gnupg lsb-release locales \
  sudo wget curl \
  git-core unzip unrar \
  && locale-gen $LANG && update-locale LANG=$LANG \
  && sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
  && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && apt-get update && apt-get -y upgrade

# Add postgresql-$POSTGRESQL_VER repository
# RUN echo "deb http://apt.postgresql.org/pub/repos/apt jammy-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
#   && wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc

# Get packages
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  apache2 \
  cron \
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
  postgresql-$POSTGRESQL_VER \
  postgresql-client-$POSTGRESQL_VER \
  postgresql-$POSTGRESQL_VER-postgis-3 \
  postgresql-$POSTGRESQL_VER-postgis-3-scripts \
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
  vim \
  && apt-get clean autoclean \
  && apt-get autoremove --yes \
  && rm -rf /var/lib/{apt,dpkg,cache,log}/


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

# Icon
RUN wget -O /var/www/html/favicon.ico https://www.openstreetmap.org/favicon.ico

# Create volume directories
RUN mkdir -p /run/tirex/ \
  && mkdir -p /home/$USER/src/ \
  && mkdir -p /data/database/ \
  && mkdir -p /data/style/ \
  && mkdir -p /data/config \
  && chown -R $USER: /run/tirex/ \
  ;

# Copy config files
COPY config/postgresql.custom.conf /data/config
COPY config/tirex.conf /data/config
COPY config/mapnik.conf /data/config
COPY config/region.conf /data/config
COPY config/tirex-region.conf /data/config
COPY config/index.html /data/config

# Install helper scripts
COPY --from=compiler-helper-script /root/regional /home/$USER/src/regional
COPY --from=compiler-stylesheet /root/openstreetmap-carto /home/$USER/src/openstreetmap-carto-backup
COPY --from=compiler-osm2pgsql /root/osm2pgsql/build/osm2pgsql /usr/local/bin/osm2pgsql
COPY --from=compiler-osm2pgsql /root/osm2pgsql/scripts/osm2pgsql-replication /usr/local/bin/osm2pgsql-replication


# Start running
COPY run.sh /
ENTRYPOINT ["/run.sh"]
CMD []
#EXPOSE 80 8080 5432
EXPOSE 80 8080
