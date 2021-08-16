Cut over plan: migration from ReviewDB to NoteDB
==

Once the cut-over actions will be reviewed and agreed, all the operational side
of the cut-over should be automated to reduce possible human mistakes.

Prerequisites
==

1. To control on how many threads dedicate to the online migration(by default 1 thread is dedicated which is definitely not enough to perform the
migration in a reasonable amount of time) increase the value in  `etc/gerrit.config`
```
[notedb]
   onlineMigrationThreads = <number of threads>
```
Please have in mind that increasing the number of threads will cause higher load on the running server (you should test
migrations in a staging environment with different value to understand what
suits better your environment).

2. Make sure the latest version of HA plugin is in use (https://gerrit-ci.gerritforge.com/view/Plugins-stable-2.16/job/plugin-high-availability-bazel-stable-2.16/130/)

3. Adjust JGIT parameters and Heap size to handle the increased number of refs: after the NoteDB migration each repo will contain much more refs than before, hence the JGIT parameters need to be tuned with the new values. And Gerrit will need to be restarted.

Migration and testing
==

## Prerequisites

1. Schedule maintenance window to avoid alarms flooding

2. Announce Gerrit upgrade via the relevant channels

3. Disable replication of refs/changes/**/meta refs: During the online migration to NoteDb a large number of new refs will be created. This could impact replication performance, hence replication might have to be disabled. This can be done in two ways:
  1. By disabling replication from gerrit instance 
    Pros:
      - Easy to implement
      - We can disable replication to replicas but keep replication to the DR instance
    Cons:
      - If on gerrit instance 1 someone will modify a change which is already migrated to the NoteDb(by adding some patch-set or comment) it will trigger replication of meta ref as well. This will increase the replication traffic for gerrit instance 1
      - We must schedule a “replication maintenance window”  and trigger replication of meta refs to all replicas and make a full aggressive GC of the repos on the replicas. During that period of time performance of replication will decrease.
      - With this solution we are not able to permanently block replication of meta refs to replica nodes even if replica nodes don't require them.
  2. By creating a simple plugin to extend replication functionality and allow to filter out meta refs from replication.
    Pros:
      - By filtering out meta refs on both primary instances we ensure that replication load and performance will not be impacted and after during the online migration to NoteDb
      - We can permanently block meta refs replication by filtering out those refs
    Cons:
      - Requires additional development time
      - We will not replicate meta refs to the DR instance so in case of failure this data will be lost. This can be solved by implementing enabled/disabled lists and enable meta refs replication to the DR node.

4. Optional backup of the git repositories. This step is just a precaution because migration to NoteDb does not remove or modify existing data, just create new refs. In that case rollback is just configuration change plus clean up for extra refs.
To create a backup of the git repositories for each repository call: git clone --mirror 


5. Update ReviewDB column: NoteDB allows longer subjects in the commit message than ReviewDB. During the trial mode, i.e.: write on both DBs, we might encounter erros when writing in ReviewDB. Updating the tables as follow will avoid it:
`ALTER TABLE changes ALTER COLUMN original_subject TYPE varchar(65535);`
`ALTER TABLE changes ALTER COLUMN subject TYPE varchar(65535);`


## 1. Enable online migration and trial mode

In this step you will enable the migration for one of the primary gerrit.

As part of this step you will also enable "trial mode" so that data is kept in
sync between ReviewDB and NoteDB.

1.1 Shutdown all gerrit primary instances

1.2 On the primary node trigger offline migration to NoteDb:
```
java -Xmx128g -jar /opt/gerrit/bin/gerrit.war migrate-to-note-db --trial --reindex false -d /opt/gerrit
```

Wait for the migration to finish. When done following message will be printed:
```
NoteDB Migration complete.
```

1.3 Rollout configuration changes to the secondary gerrit instance in a file named `etc/notedb.config`

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

1.4. Perform Garbage Collection of all repositories.
The conversion to NoteDb creates a huge fragmentation and the repos may become increasingly slow. The production may not be able to keep-up with the load without an aggressive GC.

At this point all existing changes have been migrated and new changes are stored
in both reviewDb and noteDb. You can leave Gerrit with this configuration for a
period of time (hours, days) to ensure everything worked as expected, however,
bear in mind that Gerrit is performing extra work to ensure reviewDb and noteDb
are in sync.

When testing the migration you should make sure gerrit can take your production
load when in trial mode.

Note: With NoteDb it is more likely to have a random lock failure on Git, because of continuous updates of the ‘/meta’ ref but Gerrit contains build in auto-retry mechanism to mitigate this issue. Due to the nature of the trial mode(writes to ReviewDb and NoteDb) Gerrit cannot guarantee that operations are idempotent. Because of that, the auto-retry mechanism is disabled in the trial mode. This can cause significant increas of issues related to the JGit locking failures.


1.5 Start all gerrit primary instances.

##### How to assess success for this step

* Check there are no new exceptions in the `logs/error_log` file.
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

## 2. Read and Write to NoteDB (no ReviewDB)

This is the *final* step in the migration to NoteDB. In this step you will
configure Gerrit to read and write to NoteDB only and no longer keep reviewDb
in sync.

Please be aware that this is a no-rollback stage: as new changes will be only
written to noteDb, rolling back after this point would mean that those changes
will not be available in ReviewDB and will be lost.

2.1. Optional backup of the git repositories. This step is just a precaution because migration to NoteDb does not remove or modify existing data, just create new refs. In that case rollback is just configuration change plus clean up for extra refs.
To create a backup of the git repositories for each repository call: git clone --mirror

2.2. Roll out the following configuration to primary gerrit, in the
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

2.3. Roll out the above configuration to secondary gerrit too, in the
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

After the step 2 relational database is used only to keep schama version, to simplify
the architecture current relational database can be replaced with embeded H2 database.

3.1. Start Gerrit docker images
docker run -ti -p 8080:8080 -p 29418:29418 gerritcodereview/gerrit:2.16.27

3.2. Copy database file to local disk
docker cp <container id>:/var/gerrit/db/ReviewDB.h2.db <local path>

3.3. For both nodes copy provided database files to <gerrit>/db

3.4. For both nodes replace database configuration in `etc/gerrit.config` with following:
```
[database]
        type = h2
        database = db/ReviewDB
```

3.5. For both nodes remove following section from  `/etc/secure.config`
```
[database]
        password = ...
```

3.6. Restart all gerrit nodes

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