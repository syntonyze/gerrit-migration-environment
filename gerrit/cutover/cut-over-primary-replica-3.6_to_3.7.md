Cut over plan: migration from Gerrit version 3.6.6 to 3.7.4
==

This migration is intended for a primary/replica Gerrit.

Glossary
==

* primary: Gerrit instance receiving both read and write traffic
* replica: Gerrit instance receiving only read traffic
* git repositories: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described cutover plan will migrate one node at a time to mitigate the service degradation.
The system will be in readonly while the primary instance won't be reachable.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

We suggest to use [Gatling](https://gatling.io/) to compare performance between releases
before the upgrade. [Here](https://github.com/GerritForge/gatling-sbt-gerrit-test)
an example of test suite. This suite is just an example and doesn't provide an exhaustive
test coverage.

*NOTE*: the following instructions describe a migration for Gerrit running in a mutable installation.
When using Docker, immutable images will need to be created, reflecting configuration and
software versions described.

Pre-cutover
==

* Java >= 11.0.10 is needed. `getCurrentThreadAllocatedBytes` is now used and available from
   Java >= 11.0.10. See [change](https://gerrit-review.googlesource.com/c/gerrit/+/335625).

* Gerrit 3.7 introduces [Lit](https://lit.dev/) as frontend framework. Existing UI plugins
  might not be compatible.

* The query predicates `star:ignored`, `is:ignored` and `star:star` are not supported anymore.
  The latter is identical to `is:starred` or `has:star`. Custom dashboard or script relying on
  them must be amended.

* Label's `copy*` [function](https://gerrit-documentation.storage.googleapis.com/Documentation/3.6.4/config-labels.html#label_copyAnyScore)
  are already deprecated in 3.6 and they will be dismissed in 3.7. They will be automatically
  migrated to `copyCondition` during the [upgrade](https://gerrit-documentation.storage.googleapis.com/Documentation/3.6.4/config-labels.html#label_copyCondition).
  If using `copy*` function in 3.6 make sure the label behaviours is still as expected after the migration.

* Ban modifications to label functions. Label functions can only be set to
  `{NO_BLOCK, NO_OP, PATCH_SET_LOCK}`.  Label functions also cannot be deleted (because the
  default label function is MAX_WITH_BLOCK). This is added to prevent new
  usages of label functions. Use submit requirements instead.

* SSH queries don't show commit-message anymore unless `--commit-message` is provided.
  Scripts relying on it must be amended.

* `copyAllScoresIfNoChange` is deprecated and migrated in favour of [copyCondition](https://gerrit-review.googlesource.com/Documentation/config-labels.html#label_copyCondition).
  If `copyAllScoresIfNoChange` is used, refer to this [change](https://gerrit-review.googlesource.com/c/gerrit/+/334325)
  for more details.

* Update `change.maxPatchSets` default value from 1500 to 1000.

* Full release notes for 3.7 can be found [here](https://www.gerritcodereview.com/3.7.html)

* Download new plugins and war files:
    - Gerrit 3.7.2 war file can be found in
      the [Gerrit Code Review 3.7 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.7.2.war).
      This war file contains also all core plugins:
        * codemirror-editor
        * commit-message-length-validator
        * delete-project
        * download-commands
        * gitiles
        * hooks
        * plugin-manager
        * replication
        * reviewnotes
        * singleusergroup
        * webhooks

    - Download additional plugins and libraries from [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.7/)

 * Make sure custom plugins are compatible with the new Gerrit version

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration
==

Gerrit 3.7 and 3.6 can coexist. This cutover plan will first migrate the primary instance and then the replicas.

1. Make sure to have [`httpd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#http)
   and [`sshd.gracefulStopTimeout`](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#sshd) set.
   A good value is the max expected time to clone a repository.
2. Make sure `gerrit.experimentalRollingUpgrade` is set to `true`
3. Stop Gerrit process on gerrit-1
4. Backup git repositories, caches and indexes
5. Upgrade plugins, lib and war file on gerrit-1
6. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.6.6.war init -d $GERRIT_SITE \
  --install-plugin codemirror-editor \
  --install-plugin commit-message-length-validator \
  --install-plugin delete-project \
  --install-plugin download-commands \
  --install-plugin gitiles \
  --install-plugin hooks \
  --install-plugin replication \
  --install-plugin reviewnotes \
  --install-plugin singleusergroup \
  --install-plugin webhooks \
  --batch
```

   *Note*: that you should remove any core plugin you don't want to install

The output will be similar to the following:

   ```shell
    Migrating data to schema 185 ...
    Migrating label configurations
    ... using 10 threads ...
    ... (XXX s) Migrated label configurations of all X projects to schema 185
   ```

This output shows the schema upgrade from `184` to `185`.

**NOTE**: The migration of all projects' labels configs is done only during the first Gerrit
init run. On all the other nodes the scanning of all repositories takes place
but does nothing because the migration is idempotent.

**NOTE**: Gerrit does a full scan of all projects during the Schema 185 migration.
Assess in staging how much memory is needed and consider running with an additional
`-Xmx<>` which would allocate enough memory for the init to complete.

7. Run project reindex offline. Consider increasing memory configuration (`-Xmx<>`) if
the memory allocated is not enough for the reindexing.
See below an example of reindex with 60g of heap:

```shell
  java -jar -Xmx60g <path-to-war-file>/gerrit-3.7.2.war reindex --verbose -d $GERRIT_SITE
```

* Indexes will be migrated from:

  ```shell
    [index "accounts_0011"]
	    ready = true
    [index "changes_0077"]
	    ready = true
    [index "groups_0008"]
	    ready = true
    [index "projects_0004"]
	    ready = true
  ```
    to:

  ```shell
    [index "accounts_0012"]
	    ready = true
    [index "changes_0079"]
	    ready = true
    [index "groups_0009"]
	    ready = true
    [index "projects_0005"]
	    ready = true
  ```

**NOTE**: the data migration happens only for the first node, for **ALL** the others nodes,
the project's `refs/meta/config` is unchanged and therefore the following steps, `#8` and `#9`,
aren't needed anymore.

8. Check for all projects' configs that have been migrated during the init of v3.7.
Push the `refs/meta/config` to **ALL** the other nodes *behind* Gerrit's back, for example:

```shell
find . -name '*.git' -type d | \
while read dir
  do pushd $dir
  (git log --oneline refs/meta/config | grep 'Migrate label configs to copy conditions') && \
    git push <REMOTE URL><REMOTE PATH>/$dir refs/meta/config:refs/meta/config
  popd
done > ~/post-migration-push.log 2> ~/post-migration-push.err
```

9. Start Gerrit
10. Test the node is working fine.

Observation period (1 week?)
===

* The primary/replica setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the replica nodes can be completed
* Keep the migrated node under observation as you did for the other
* Replicas will have to be migrated one by one to minimize the impact on the system.
  Observation period can be eventually adjusted to shorten the complete rollout of the new version.

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.6.6
3. Downgrade the schema version from 185 to 184 as explained [here](https://www.gerritcodereview.com/3.7.html#downgrade):
    `git update-ref refs/meta/version $(echo -n 184|git hash-object -w --stdin)`

    See git hash-object and git update-ref.

    `NOTE: The migration of the label config to copy-condition performed in v3.7.x init step is idempotent and can be run many times. Also v3.6.x supports the copy-condition and therefore the migration does not need to be downgraded.`
4. Stop Gerrit
5. Run init on gerrit

        java -jar <path-to>/gerrit-3.6.6.war init -d $GERRIT_SITE \
        --install-plugin codemirror-editor \
        --install-plugin commit-message-length-validator \
        --install-plugin delete-project \
        --install-plugin download-commands \
        --install-plugin gitiles \
        --install-plugin hooks \
        --install-plugin replication \
        --install-plugin reviewnotes \
        --install-plugin singleusergroup \
        --install-plugin webhooks \
        --no-auto-start \
        --batch

5. Reindex Gerrit
    `java -jar gerrit-3.5.6.war reindex -d site_path`

6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system