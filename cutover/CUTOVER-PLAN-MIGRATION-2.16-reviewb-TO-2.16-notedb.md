Cut over plan: migration from ReviewDB to NoteDB
==

The described migration plan will allow no downtime. Both Read and Write
operation will be allowed during the migration.

There will only be a short readonly window to allow backing up the git
repositories and ReviewDB.

Once the cut-over actions will be reviewed and agreed, all the operational side
of the cut-over should be automated to reduce possible human mistakes.

Prerequisites
==

1. Schedule maintenance window to avoid alarms flooding

2. Announce Gerrit upgrade via the relevant channels

3. Put both primary and secondary gerrit in Read only mode

4. Take a snapshot Git repos, review DB, caches indexes


Migration and testing
==

## 1. Enable online migration and trial mode

In this step you will enable the online migration for one of the primary gerrit.
This will start a thread to migrate changes from ReviewDB to NoteDB.

Once started, it is safe to restart the server at any time; the migration will
pick up where it left off. Migration progress will be reported to the Gerrit
logs.

As part of this step you will also enable "trial mode" so that data is kept in
sync between ReviewDB and NoteDB.

 1.1. Rollout configuration changes to the primary gerrit instance in a file
 named `etc/notedb.config`

```
[noteDb "changes"]
   primaryStorage = review db
   disableReviewDb = false
   read = false
   sequence = false
   write = true
   autoMigrate = true
   trial = true
```

 1.2 Rollout configuration changes to the secondary gerrit instance in a file
 named `etc/notedb.config`.
 This is just in case the node will fail over the secondary node during migration.

```
[noteDb "changes"]
   primaryStorage = review db
   disableReviewDb = false
   read = false
   sequence = false
   write = true
   autoMigrate = false
   trial = true
```

*Note*:
You also have control on how many threads to dedicate to the online migration,
by default *1* thread is dedicated which is definately not enough to perform the
migration in resonable amount of time.
Increasing this value allows speeding up online migration from reviewDb to noteDb
at the expense of imposing a higher load on the running server (you should test
migrations in a staging environment with different value to understand what
suits better your environment).

If you want to dedicate more threads to the online migration, set this value
in the `etc/gerrit.config` file and restart gerrit instance, for example:

```
[notedb]
   onlineMigrationThreads = 2
```

##### How to assess success for this step

* Check the `etc/error_log` file for evidence of the online migrator thread:
  (this grep should find at one entry)

```
grep 'Starting online NoteDb migration' logs/error_log
```

* Check that projects changes are being rebuilt:
  (this grep should find many entries)
```
grep 'Rebuilding project' logs/error_log
```

* Check there are no new exceptions in the `logs/error_log` file:

## 2. Wait the online migration to finish

Since you have enabled the online migration for the primary gerrit, after
restarting it you will see evidence of the online migration in the `error_log`.

```
[OnlineNoteDbMigrator] INFO  com.google.gerrit.server.notedb.rebuild.OnlineNoteDbMigrator : Starting online NoteDb migration
```

The migration will run for a period of time that depends on your system
resources, system utilization, number of projects and changes.

You should be able to get an estimate when testing this in a staging environment.

You will know the migration has finished by looking at the `error_log` for an
entry similar to:

```
[OnlineNoteDbMigrator] INFO  com.google.gerrit.server.notedb.rebuild.OnlineNoteDbMigrator : Online NoteDb migration completed in 10823s
```

At this point all existing changes have been migrated and new changes are stored
in both reviewDb and noteDb. You can leave Gerrit with this configuration for a
period of time (hours, days) to ensure everything worked as expected, however,
bear in mind that Gerrit is performing extra work to ensure reviewDb and noteDb
are in sync.

When testing the migration you should make sure gerrit can take your production
load when in trial mode.

##### How to assess success for this step

* The migration state at the end of this process should be `READ_WRITE_NO_SEQUENCE`
  look for evidence of it in the logs (this grep should find one entry):
  ```
   grep READ_WRITE_NO_SEQUENCE logs/error_log
  ```
* New changes can be created with no errors
* Existing changes can be updated with no errors
* Existing changes can still be browsed through the UI with no errors
* All changes in reviewdb should now have an equivalent metadata ref in notedb.

In reviewDB:
```
SELECT dest_project_name, COUNT(*) FROM changes GROUP BY dest_project_name;

dest_project_name	count
project1	1234
project2	2345

```

For each project, count the number of meta refs, for example in
<gerrit>/git/$project.git
```
git show-ref **/meta | wc -l
1234
```

## 3. Dual write - Read from NoteDB but keep ReviewDB primary

At the end of step 3, once the migration has finished, the online migrator
will automatically change the `notedb.config` file to read from NoteDb, by
setting:

`notedb.changes.read=true`

This ensures that change data is written to and read from NoteDb, but ReviewDb
is still the source of truth. You should make sure the same configuration is
also applied to the *secondary* node by rolling out the following configuration
to the primary gerrit instance, in the `etc/notedb.config` configuration file.

```
[noteDb "changes"]
   primaryStorage = review db
   disableReviewDb = false
   read = true
   sequence = false
   write = true
   autoMigrate = false
   trial = true
```

Next step is a stage with no-rollback so we suggest to leave Gerrit with this configuration
for a longer period of time(days) to ensure everything worked as expected, however, bear in mind
that Gerrit is performing extra work to ensure reviewDb and noteDb
are in sync.

When testing the migration you should make sure gerrit can take your production
load when in trial mode.

##### How to assess success for this step

* New changes can be created with no errors
* Existing changes can be updated with no errors
* Existing changes can still be browsed through the UI with no errors
* All changes in reviewdb should have an equivalent metadata ref in notedb.

In reviewDB:
```
SELECT dest_project_name, COUNT(*) FROM changes GROUP BY dest_project_name;

dest_project_name	count
project1	1234
project2	2345

```

For each project, count the number of meta refs, for example in
<gerrit>/git/$project.git
```
git show-ref **/meta | wc -l
1234
```

## 4. Read and Write to NoteDB (no ReviewDB)

This is the *final* step in the migration to NoteDB. In this step you will
configure Gerrit to read and write to NoteDB only and no longer keep reviewDb
in sync.

Please be aware that this is a no-rollback stage: as new changes will be only
written to noteDb, rolling back after this point would mean that those changes
will not be available in ReviewDB and will be lost.

4.1. Put both primary and secondary gerrit in Read only mode
4.2. Take a snapshot of Git repos, review DB, caches and indexes
4.3. Put primary and secondary gerrit in Read/Write mode
4.4. Roll out the following configuration to primary gerrit, in the
 `etc/notedb.config` file.

```
[noteDb "changes"]
   primaryStorage = review db
   disableReviewDb = false
   read = true
   sequence = false
   write = true
   autoMigrate = true
   trial = false
```

With this configuration the online migration task will finalize the migration
to noteDb and stop writing to reviewDb altogether. At the end of this operation
the `etc/notedb.config` file will automatically be updated with this content:

```
[noteDb "changes"]
   primaryStorage = note db
   disableReviewDb = true
   read = true
   sequence = true
   write = true
   autoMigrate = false
   trial = false
```

4.5. Roll out the above configuration to secondary gerrit too, in the
`etc/notedb.config` file.

```
[noteDb "changes"]
   primaryStorage = note db
   disableReviewDb = true
   read = true
   sequence = true
   write = true
   autoMigrate = false
   trial = false
```

##### How to assess success for this step

* New changes can be created with no errors
* Existing changes can be updated with no errors
* Existing changes can still be browsed through the UI with no errors
* The migration has now terminated to noteDb (the following grep should return
  one entry).

```
grep 'Migration state: READ_WRITE_WITH_SEQUENCE_NOTE_DB_PRIMARY => NOTE_DB' logs/error_log
```
* No new Exceptions can be found in the `logs/error_log`
* New changes should no longer be recorded in the reviewDb

Database cleanup
==

After the step 4 relational database is used only to keep schama version, to simplify
the architecture current relational database can be replaced with embeded H2 database.

5.1. For both nodes copy provided database files to <gerrit>/db

5.2. For both nodes replace database configuration in `etc/gerrit.config` with following:
```
[database]
        type = h2
        database = db/ReviewDB
```
5.3. Restart all gerrit nodes

Rollback strategy
==

As previously documented, prior to starting any operation all the data will be
backed up (git repositories, review db, indexes) to allow recovery in case of
failure.

At any stage of the migration a rollback can be performed by updating the
`etc/notedb.config` on both primary and secondary node as follows:

```
[noteDb "changes"]
   autoMigrate = false
   trial = false
   write = false
   read = false
   sequence = false
   primaryStorage = review db
   disableReviewDb = false
```

#### Clean up

If a rollback is performed, the git repositories might already contain extra
refs used by NoteDB. You can proceed to clean them up by using the
`remove_notedb_refs.sh` [provided](https://gerrit.googlesource.com/gerrit/+/refs/heads/master/contrib/remove-notedb-refs.sh)

Restore of the backed up data can be used as last resource rollback if needed.

Useful references
==

[1]: [Gerrit 2.16 documentation](https://www.gerritcodereview.com/2.16.html)

[2]: [Plugins artifacts](https://gerrit-ci.gerritforge.com)

[3]: [Zero downtime Gerrit](https://www.slideshare.net/lucamilanesio/zerodowntime-gerrit-code-review-upgrades)

[4]: [NoteDB migration](https://gerrit-review.googlesource.com/Documentation/note-db.html)

[5]: [GerritHub is on NoteDB](https://gitenterprise.me/2018/04/27/gerrithub-is-on-notedb-with-a-bump)