#!/bin/bash

set -euo pipefail

function cartoBuild() {
    # if there is no custom style mounted, then use osm-carto
    if [ ! "$(ls -A /data/style/)" ]; then
        mv /home/_tirex/src/openstreetmap-carto-backup/* /data/style/
        rm -fr /home/_tirex/src/openstreetmap-carto-backup/
    fi

    # carto build
    if [ ! -f /data/style/mapnik.xml ]; then
        cd /data/style/
        carto ${NAME_MML:-project.mml} > mapnik.xml
    fi
}

function createPostgresConfig() {
    cp /data/config/postgresql.custom.conf /etc/postgresql/15/main/conf.d/postgresql.custom.conf
    # sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/15/main/conf.d/postgresql.custom.conf
    cat /etc/postgresql/15/main/conf.d/postgresql.custom.conf
}

function setupGisDB() {
    if [ ! "$( sudo -u postgres psql -XtAc "SELECT usename FROM pg_user WHERE usename='_tirex'" )" ]; then
        sudo -u postgres createuser _tirex
        if [ ! "$( sudo -u postgres psql -XtAc "SELECT 1 FROM pg_database WHERE datname='gis'" )" ]; then
            sudo -u postgres createdb -E UTF8 -O _tirex gis
            sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
            sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO _tirex;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geography_columns OWNER TO _tirex;"
            sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO _tirex;"
        fi
    fi
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER _tirex PASSWORD '${PGPASSWORD:-_tirex}'"
}

function setupTirex() {
    if [ ! -f /etc/tirex/renderer/mapnik/region.conf ]; then
        sed -i -E "s,#master_rendering_timeout=,master_rendering_timeout=," /etc/tirex/tirex.conf
        sed -i -E "s,#backend_manager_alive_timeout=,backend_manager_alive_timeout=," /etc/tirex/tirex.conf
        sed -i -E "s,procs=[0-9]+,procs=${THREADS:-4}," /etc/tirex/renderer/mapnik.conf
        sed -i -E "s,fontdir=.*,fontdir=/usr/share/fonts," /etc/tirex/renderer/mapnik.conf

        mv /etc/tirex/renderer/mapnik/tirex-example.conf /etc/tirex/renderer/mapnik/region.conf
        sed -i -E "s,name=.*,name=region," /etc/tirex/renderer/mapnik/region.conf
        sed -i -E "s,tiledir=.*,tiledir=/data/tiles/region," /etc/tirex/renderer/mapnik/region.conf
        sed -i -E "s,maxz=.*,maxz=20," /etc/tirex/renderer/mapnik/region.conf
        sed -i -E "s,mapfile=.*,mapfile=/data/style/mapnik.xml," /etc/tirex/renderer/mapnik/region.conf
        
        mkdir -p /etc/tirex/disabled
        mv /etc/tirex/renderer/test* /etc/tirex/disabled

        rm -fr /data/tiles/tirex-example
        mkdir -p /data/tiles/region
        chown -R _tirex: /data/tiles

        mv /usr/share/tirex/example-map /usr/share/tirex/region
        sed -i -E "s,/tiles/tirex-example/,/," /usr/share/tirex/region/index.html
        sed -i -E "s,maxZoom: [0-9]+,maxZoom: 20," /usr/share/tirex/region/index.html

        a2disconf tirex tirex-example-map
        cp /data/config/tirex-region.conf /etc/apache2/conf-available
        a2enconf tirex-region
    fi
}


if [ "$#" -ne 1 ]; then
    echo "usage: <import|run|debug>"
    echo "commands:"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and tirex to serve tiles at /{z}/{x}/{y}.png"
    echo "    debug: Start an infinite commande to allow shell access to container"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    exit 1
fi

set -x


if [ "$1" == "import" ]; then
    # Make sure the import is not already done before overwriting
    if [ -f /data/database/planet-import-complete ]; then
        echo "WARNING: /data/database/planet-import-complete already exists."
        echo "Delete this file if you want to redo the import."
        exit 1
    fi


    # Setup carto
    cartoBuild
    
    # Ensure that database directory is in right state
    chown _tirex: /data/database/
    mkdir -p /data/database/postgres/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/15/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    setupGisDB
    setPostgresPassword

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp /data/region.osm.pbf`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u _tirex openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown _tirex: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        sudo -E -u _tirex osm2pgsql -d gis --create --slim -G --hstore  \
        --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
        --number-processes ${THREADS:-4}  \
        --cache ${CACHE:-2500} \
        -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
        /data/region.osm.pbf  \
        ${OSM2PGSQL_EXTRA_ARGS:-}  \
        ;
    else
        sudo -E -u _tirex osm2pgsql -d gis --create --slim -G --hstore --drop  \
        --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
        --number-processes ${THREADS:-4}  \
        --cache ${CACHE:-2500} \
        -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
        /data/region.osm.pbf  \
        ${OSM2PGSQL_EXTRA_ARGS:-}  \
        ;
    fi

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown _tirex: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -E -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    #Import external data
    chown -R _tirex: /home/_tirex/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        cd /data/style
        sudo -E -u _tirex python3 /data/style/scripts/get-external-data.py -C -c /data/style/external-data.yml -D /data/style/data
    fi

    #Import missing fonts
    if [ -f /data/style/scripts/get-fonts.sh ] && [ $(ls /data/style/fonts | wc -l) -lt 104 ]; then
        cd /data/style
        sudo -E -u _tirex /data/style/scripts/get-fonts.sh
        cd fonts
        for i in *; do [[ ! -n `find /usr/share/fonts -name $i` ]] && cp $i /usr/share/fonts; done
    fi

    # Register that data has changed for mod_tile caching purposes
    sudo -u _tirex touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Setup carto
    cartoBuild
    
    # Clean /tmp
    rm -rf /tmp/*

    # migrate old files
    if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
        mkdir /data/database/postgres/
        mv /data/database/* /data/database/postgres/
    fi
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
    fi
    if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
        mv /data/tiles/data.poly /data/database/region.poly
    fi

    # sync planet-import-complete file
    if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Fix postgres data privileges
    chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

    # # Configure Apache CORS
    # if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
    #     echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    # fi

    # Configure tirex
    setupTirex
    service apache2 restart

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    setPostgresPassword

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u _tirex touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u _tirex touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u _tirex touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u _tirex touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    sudo -u _tirex /usr/bin/tirex-master -f &
    sudo -u _tirex /usr/bin/tirex-backend-manager -f &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

if [ "$1" == "debug" ]; then
    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    child=$!
    wait "$child"

    exit 0
fi


echo "invalid command"
exit 1
