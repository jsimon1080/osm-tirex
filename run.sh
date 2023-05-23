#!/bin/bash

set -euo pipefail

cartoBuild() {
    # if there is no custom style mounted, then use osm-carto
    if [ ! "$(ls -A /data/style/)" ]; then
        cp -a /home/$USER/src/openstreetmap-carto-backup/* /data/style/
    fi
    ln -snf /data/style /home/$USER/src/openstreetmap-carto

    # carto build
    if [ ! -f /data/style/mapnik.xml ]; then
        cd /data/style/
        carto ${NAME_MML:-project.mml} > mapnik.xml
    fi
}

addDBConfig() {
    ln -snf /data/config/postgresql.custom.conf /etc/postgresql/$POSTGRESQL_VER/main/conf.d/postgresql.custom.conf
    # cat /etc/postgresql/$POSTGRESQL_VER/main/conf.d/postgresql.custom.conf

    if [ ! -d /data/database/postgres ]; then
        mv /var/lib/postgresql/$POSTGRESQL_VER/main /data/database/postgres
    else
        rm -fr /var/lib/postgresql/$POSTGRESQL_VER/main
    fi
    ln -snf /data/database/postgres /var/lib/postgresql/$POSTGRESQL_VER/main

    # Ensure that database directory is in right state
    chown $USER: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$POSTGRESQL_VER/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Configure PosgtreSQL
    #   && echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/$POSTGRESQL_VER/main/pg_hba.conf \
    #   && echo "host all all ::/0 md5" >> /etc/postgresql/$POSTGRESQL_VER/main/pg_hba.conf
}

setupGisDB() {
    if [ ! "$( sudo -u postgres psql -XtAc "SELECT usename FROM pg_user WHERE usename='$USER'" )" ]; then
        sudo -u postgres createuser $USER
        if [ ! "$( sudo -u postgres psql -XtAc "SELECT 1 FROM pg_database WHERE datname='gis'" )" ]; then
            sudo -u postgres createdb -E UTF8 -O $USER gis
            sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
            sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO $USER;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geography_columns OWNER TO $USER;"
            sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO $USER;"
            sudo -u postgres psql -c "ALTER USER $USER PASSWORD '${PGPASSWORD:-$USER}'"
        fi
    fi
}

setupTirex() {
    rm -fr /etc/tirex/renderer/test* /etc/tirex/renderer/mapnik/tirex-example.conf

    ln -snf /data/config/tirex.conf /etc/tirex/tirex.conf
    ln -snf /data/config/mapnik.conf /etc/tirex/renderer/mapnik.conf
    ln -snf /data/config/region.conf /etc/tirex/renderer/mapnik/region.conf

    rm -fr /var/cache/tirex/tiles && ln -snf /data/tiles /var/cache/tirex/tiles
    mkdir -p /data/tiles/region
    chown -R $USER: /data/tiles

    if [ ! -d /usr/share/tirex/region ]; then
        mv /usr/share/tirex/example-map /usr/share/tirex/region
    fi
    
    ln -snf /data/config/index.html /usr/share/tirex/region/index.html
    ln -snf /data/config/tirex-region.conf /etc/apache2/conf-available/tirex-region.conf
    a2disconf tirex tirex-example-map
    a2enconf tirex-region
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
    # Give an error if the import is already done and exit to avoid overwriting the database.
    if [ -f /data/database/planet-import-complete ]; then
        set -
        sleep 0.1
        echo ""
        echo "ERROR: /data/database/planet-import-complete already exists."
        echo "Delete this file if you want to redo the import."
        echo "Location with the default Docker configuration : /var/lib/docker/volumes/osm-tirex_data/_data/"
        echo ""
        exit 1
    fi

    # Setup carto
    cartoBuild
    
    # Initialize PostgreSQL
    addDBConfig
    service postgresql start
    setupGisDB

    #Import external data
    chown -R $USER: /home/$USER/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        cd /data/style
        sudo -E -u $USER python3 /data/style/scripts/get-external-data.py -C -c /data/style/external-data.yml -D /data/style/data
    fi

    #Import missing fonts
    if [ -f /data/style/scripts/get-fonts.sh ] && [ $(ls /data/style/fonts | wc -l) -lt 104 ]; then
        cd /data/style
        sudo -E -u $USER /data/style/scripts/get-fonts.sh
        cd fonts
        for i in *; do [[ ! -n `find /usr/share/fonts -name $i` ]] && cp $i /usr/share/fonts; done
    fi

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

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown $USER: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    sudo -E -u $USER osm2pgsql -d gis --create --slim -G --hstore  \
    --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
    --number-processes ${THREADS:-4}  \
    --cache ${CACHE:-2500} \
    -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
    /data/region.osm.pbf  \
    ${OSM2PGSQL_EXTRA_ARGS:-}  \
    ;

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -E -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    # Register that data has changed for mod_tile caching purposes and indicate that the import is completed
    sudo -u $USER touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Warn about missing planet-import-complete file and exit.
    if [ ! -f /data/database/planet-import-complete ]; then
        set -
        sleep 0.1
        echo ""
        echo "WARNING: /data/database/planet-import-complete is missing."
        echo "This usually means that the import process did non complete successfully."
        echo "Use the 'command import' statement in the docker-compose.yml file."
        echo ""
        exit 1
    fi

    # sync planet-import-complete files
    if [ -f /data/tiles/planet-import-complete ] && [ ! -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if [ -f /data/database/planet-import-complete ] && [ ! -f /data/tiles/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Setup carto
    cartoBuild
    
    # Clean /tmp
    rm -rf /tmp/*

    # # Configure Apache CORS
    # if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
    #     echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    # fi

    # Initialize PostgreSQL
    addDBConfig
    service postgresql start

    # Configure tirex
    setupTirex
    service apache2 restart

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    sudo -u $USER /usr/bin/tirex-master -f &
    sudo -u $USER /usr/bin/tirex-backend-manager -f &
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
