#!/bin/sh

echo "Init gerrit..."
java -jar /tmp/gerrit.war init --batch --install-all-plugins --dev -d /var/gerrit

echo "Reindexing phase..."
cd /var/gerrit && java -jar /var/gerrit/bin/gerrit.war reindex --index groups

echo "Running gerrit..."
/var/gerrit/bin/gerrit.sh run
