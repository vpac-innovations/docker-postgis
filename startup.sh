#!/bin/bash

service postgresql start
service redis-server start
#service varnish start
psql -d carto_db_development -U postgres -c "UPDATE users SET database_host='$(hostname -f)'"

while true; do
echo "service on"
sleep 300
done