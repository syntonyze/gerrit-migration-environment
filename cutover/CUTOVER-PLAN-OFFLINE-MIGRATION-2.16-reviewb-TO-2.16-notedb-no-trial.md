Cut over plan: migration from ReviewDB to NoteDB
==

Once the cut-over actions will be reviewed and agreed, all the operational side
of the cut-over should be automated to reduce possible human mistakes.

Prerequisites
==

1. Make sure the latest version of HA plugin is in use (https://gerrit-ci.gerritforge.com/view/Plugins-stable-2.16/job/plugin-high-availability-bazel-stable-2.16/130/)

2. Adjust JGIT parameters and Heap size to handle the increased number of refs: after the NoteDB migration each repo will contain much more refs than before, hence the JGIT parameters need to be tuned with the new values. And Gerrit will need to be restarted.

3. Change DNS name of the primary nodes to have a common part. Currently in `etc/gerrit.config` auth.cookieDomain is set to `gerrit.eng.nutanix.com` but the host names are phx-it-gerrit-prod-1.eng.nutanix.com an phx-it-gerrit-prod-2.eng.nutanix.com so there is no way to directly sign in to the primary node.

Migration and testing
==

## Prerequisites

1. Schedule maintenance window to avoid alarms flooding

2. Announce Gerrit upgrade via the relevant channels

3. Disable replication of refs/changes/**/meta refs: During the migration to NoteDb a large number of new refs will be created. This could impact replication performance, hence replication might have to be disabled. This can be done in two ways:
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
      - By filtering out meta refs on both primary instances we ensure that replication load and performance will not be impacted during and after the migration to NoteDb
      - We can permanently block meta refs replication by filtering out those refs
    Cons:
      - Requires additional development time
      - We will not replicate meta refs to the DR instance so in case of failure this data will be lost. This can be solved by implementing enabled/disabled lists and enable meta refs replication to the DR node.

4. Optional backup of the git repositories. This step is just a precaution because migration to NoteDb does not remove or modify existing data, just create new refs. In that case rollback is just configuration change plus clean up for extra refs.
To create a backup of the git repositories for each repository call: git clone --mirror 


5. Update ReviewDB column: NoteDB allows longer subjects in the commit message than ReviewDB:
`ALTER TABLE changes ALTER COLUMN original_subject TYPE varchar(65535);`
`ALTER TABLE changes ALTER COLUMN subject TYPE varchar(65535);`


## 1. Start offline migration

In this step you will enable the migration for one of the primary gerrit.

This is the *final* step in the migration to NoteDB. In this step you will
configure Gerrit to read and write to NoteDB only and no longer keep reviewDb
in sync.

Please be aware that this is a no-rollback stage: as new changes will be only
written to noteDb, rolling back after this point would mean that those changes
will not be available in ReviewDB and will be lost.

1.1. Optional backup of the git repositories. This step is just a precaution because migration to NoteDb does not remove or modify existing data, just create new refs. In that case rollback is just configuration change plus clean up for extra refs.
To create a backup of the git repositories for each repository call: git clone --mirror

1.2 Shutdown all gerrit primary instances

1.3 On the primary node trigger offline migration to NoteDb:
```
java -Xmx128g -jar /opt/gerrit/bin/gerrit.war migrate-to-note-db --shuffle-project-slices --reindex false -d /opt/gerrit
```

Wait for the migration to finish. When done following messages will be printed:
```
Migration state: READ_WRITE_WITH_SEQUENCE_NOTE_DB_PRIMARY => NOTE_DB
```
and
```
NoteDB Migration complete.
```

1.4 Rollout configuration changes to the secondary gerrit instance in a file named `etc/notedb.config`

```
[noteDb "changes"]
        autoMigrate = false
        trial = false
        write = true
        read = true
        sequence = true
        primaryStorage = note db
        disableReviewDb = true
```

1.4. Perform Garbage Collection of all repositories.
The conversion to NoteDb creates a huge fragmentation and the repos may become increasingly slow. The production may not be able to keep-up with the load without an aggressive GC.

1.5. Copy git repositories to replicas, for each replica:
1.5.1. Stop Gerrit instance.
1.5.2. Copy repositories.
1.5.3. Start Gerrit instance.

1.6 Start all gerrit primary instances.

##### How to assess success for this step

* Check there are no new exceptions in the `logs/error_log` file.
* New changes can be created with no errors
* Existing changes can be updated with no errors
* Existing changes can still be browsed through the UI with no errors
* All changes in reviewdb should now have an equivalent metadata ref in notedb.

In reviewDB:
```
SELECT dest_project_name, COUNT(*) FROM changes GROUP BY dest_project_name;

dest_project_name count
project1  1234
project2  2345

```

For each project, count the number of meta refs, for example in
<gerrit>/git/$project.git
```
git show-ref **/meta | wc -l
1234
```

Database cleanup
==

After the step 1 relational database is used only to keep schama version, to simplify
the architecture current relational database can be replaced with embeded H2 database.

2.1. Start Gerrit docker images
docker run -ti -p 8080:8080 -p 29418:29418 gerritcodereview/gerrit:2.16.27

2.2. Copy database file to local disk
docker cp <container id>:/var/gerrit/db/ReviewDB.h2.db <local path>

2.3. For all nodes copy provided database files to <gerrit>/db

2.4. For all nodes replace database configuration in `etc/gerrit.config` with following:
```
[database]
        type = h2
        database = db/ReviewDB
```

2.5. For both nodes remove following section from  `/etc/secure.config`
```
[database]
        password = ...
```

2.6. Restart all gerrit nodes

Rollback strategy
==

As previously documented, prior to starting any operation all the data will be
backed up (git repositories, review db, indexes) to allow recovery in case of
failure.

Please be aware that new changes will be only written to noteDb, rolling back after
migration would mean that those changes will not be available in ReviewDB and will be
lost.

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
