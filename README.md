# gerrit-migration-environment

## What to check for migration

* check release notes
* check plugin compatibility
* timing of the operations, expecially reindexing
* reindexing: check time taken and resource usage
* check both upgrade and rollback plan with incoming RW traffic

## Useful commands

* Generate changes in bulk

```bash
while true; do git checkout -f origin/master; for i in $(seq 1 $(( ( RANDOM % 150 )  + 5 ))); do  base64 /dev/urandom | head -c $(( ( RANDOM % 10000000 )  + 100000 )) > $RANDOM-$i; done; git add . && git commit -m "Add file $(date)" && git push origin HEAD:refs/for/master
; sleep 2; done;
```

* Backup Postgres DB

```bash
```

* Restore Postgres DB

```bash
```
