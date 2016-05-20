#
# Cartodb postgres
#
FROM ubuntu:14.04
MAINTAINER Stefan Verhoeven <s.verhoeven@esciencecenter.nl>

# Configuring locales
ENV DEBIAN_FRONTEND noninteractive
RUN dpkg-reconfigure locales && \
      locale-gen en_US.UTF-8 && \
      update-locale LANG=en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN useradd -m -d /home/cartodb -s /bin/bash cartodb && \
  apt-get update && \
  apt-get install -y -q \
    postgresql-9.3 \
    postgresql-client-9.3 \
    postgresql-contrib-9.3 \
    postgresql-server-dev-9.3 \
    postgresql-plpython-9.3 \
    postgresql-9.3-plproxy \
    postgresql-9.3-postgis-2.1 \
    postgresql-9.3-postgis-2.1-scripts \
    postgis \
    git \
    pgtune \
    libicu-dev \
    build-essential \
    python2.7-dev \
    python-setuptools \
    redis-server \
    curl \
    ca-certificates \
    --no-install-recommends 

# Install NodeJS
RUN curl https://nodejs.org/download/release/v0.10.41/node-v0.10.41-linux-x64.tar.gz| tar -zxf - --strip-components=1 -C /usr

# Install rvm
RUN gpg --keyserver hkp://keys.gnupg.net --recv-keys D39DC0E3
RUN curl -L https://get.rvm.io | bash -s stable --ruby
RUN echo 'source /usr/local/rvm/scripts/rvm' >> /etc/bash.bashrc
RUN /bin/bash -l -c rvm requirements
ENV PATH /usr/local/rvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN echo rvm_max_time_flag=15 >> ~/.rvmrc
RUN /bin/bash -l -c 'rvm install 2.2.3'
RUN /bin/bash -l -c 'rvm use 2.2.3 --default'
RUN /bin/bash -l -c 'gem install bundle archive-tar-minitar'

# Install bundler
RUN /bin/bash -l -c 'gem install bundler --no-doc --no-ri'

# Setting PostgreSQL
RUN sed -i 's/\(peer\|md5\)/trust/' /etc/postgresql/9.3/main/pg_hba.conf && \
      echo "host all all 0.0.0.0/0 trust" >> /etc/postgresql/9.3/main/pg_hba.conf && \
      pgtune -T Web -c 100 -i /etc/postgresql/9.3/main/postgresql.conf -o /etc/postgresql/9.3/main/postgresql.conf.pgtune && \
      echo "listen_addresses = '*'" >> /etc/postgresql/9.3/main/postgresql.conf.pgtune && \
      mv /etc/postgresql/9.3/main/postgresql.conf /etc/postgresql/9.3/main/postgresql.conf.orig && \
      mv /etc/postgresql/9.3/main/postgresql.conf.pgtune /etc/postgresql/9.3/main/postgresql.conf


# Install schema_triggers
RUN git clone https://github.com/CartoDB/pg_schema_triggers.git && \
      cd pg_schema_triggers && \
      make all install && \
      sed -i \
      "/#shared_preload/a shared_preload_libraries = 'schema_triggers.so'" \
      /etc/postgresql/9.3/main/postgresql.conf
ADD ./template_postgis.sh /tmp/template_postgis.sh
RUN service postgresql start && /bin/su postgres -c \
      /tmp/template_postgis.sh && service postgresql stop

# Install cartodb extension
RUN git clone https://github.com/CartoDB/cartodb-postgresql && \
      cd cartodb-postgresql && \
      PGUSER=postgres make install
ADD ./cartodb_pgsql.sh /tmp/cartodb_pgsql.sh
RUN service postgresql start && /bin/su postgres -c \
      /tmp/cartodb_pgsql.sh && service postgresql stop

# Geocoder SQL client + server
RUN git clone https://github.com/CartoDB/data-services &&\
  cd /data-services/geocoder/extension && PGUSER=postgres make all install && cd / && \
  git clone https://github.com/CartoDB/dataservices-api.git &&\
  ln -s /usr/local/rvm/rubies/ruby-2.2.3/bin/ruby /usr/bin &&\
  cd /dataservices-api/server/extension && PGUSER=postgres make install &&\
  cd ../lib/python/cartodb_services && python setup.py install &&\
  cd ../../../../client && PGUSER=postgres make install &&\
  service postgresql start && \
  echo "CREATE ROLE geocoder WITH LOGIN SUPERUSER PASSWORD 'geocoder'" | psql -U postgres postgres &&\
  createdb -U postgres -E UTF8 -O geocoder geocoder &&\
  echo 'CREATE EXTENSION plpythonu;CREATE EXTENSION postgis;CREATE EXTENSION cartodb;CREATE EXTENSION cdb_geocoder;CREATE EXTENSION plproxy;CREATE EXTENSION cdb_dataservices_server;CREATE EXTENSION cdb_dataservices_client;' | psql -U geocoder geocoder &&\
  service postgresql stop

RUN mkdir /cartodb
COPY ./cartodb /cartodb
RUN cd /cartodb && \
      perl -pi -e 's/jwt \(1\.5\.3\)/jwt (1.5.4)/' Gemfile.lock && \
      /bin/bash -l -c 'bundle install' || \
      /bin/bash -l -c "cd $(/bin/bash -l -c 'gem contents \
            debugger-ruby_core_source' | grep CHANGELOG | sed -e \
            's,CHANGELOG.md,,') && /bin/bash -l -c 'rake add_source \
            VERSION=$(/bin/bash -l -c 'ruby --version' | awk \
            '{print $2}' | sed -e 's,p55,-p55,' )' && cd /cartodb && \
            /bin/bash -l -c 'bundle install'"

ADD ./create_dev_user /cartodb/script/create_dev_user
ADD ./setup_organization.sh /cartodb/script/setup_organization.sh
ENV PATH /usr/local/rvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ADD ./app_config.yml /cartodb/config/app_config.yml
ADD ./database.yml /cartodb/config/database.yml

# Setting for remote connection redis server
RUN echo "bind 0.0.0.0" >> /etc/redis/redis.conf

RUN service postgresql start && service redis-server start && \
   bash -l -c "cd /cartodb && bash script/create_dev_user || bash script/create_dev_user && bash script/setup_organization.sh" && \
   service postgresql stop && service redis-server stop

ADD ./startup.sh /opt/startup.sh
CMD ["/bin/bash", "/opt/startup.sh"]

EXPOSE 6379 5432