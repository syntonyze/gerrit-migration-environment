Cut over plan: migration from Gerrit version 3.6.4 to 3.7.2
==

This migration is intended for a multi-site Gerrit installation having following
characteristics:

* Runs Gerrit 3.6.4 in a multi-site setup

Glossary
==

* gerrit-X: the name of Gerrit primary number X in the multi site setup
* primary: Gerrit instance receiving both read and write traffic
* git repositories: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* caches: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* indexes: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration will migrate one node at a time to avoid any downtime.

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
    - Download [global-refdb library](https://repo1.maven.org/maven2/com/gerritforge/global-refdb/3.7.2/global-refdb-3.7.2.jar) and place it in `$GERRIT_SITE/bin/global-refdb.jar`

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels
3. **Important**: Make sure that all projects' configs are NOT modified during the migration on any of the nodes.
The migration to Schema 185 (included in Gerrit v3.7) triggers the processing of
all projects' configs for calculating the equivalent
[copy-condition](https://gerrit-review.googlesource.com/c/gerrit/+/334325))
for any label defined in the project. All the projects' config can **NOT** be modified until **ALL**
the nodes have been migrated.

To achieve it:
* Add the following ACL to `All-Projects`:

```
 push = block group Project Owners
 push = block group Registered Users

 submit = block group Project Owners
 submit = block group Registered Users
```

* Block the in the Load balancer (or via a groovy plugin) `POST` calls `<GERRIT URL>/projects/<projectName>/access` with
`refs/meta/config` in the body, for example:

```
POST http://localhost/projects/level1/access

{
  "add": {
    "refs/meta/config": {
      "permissions": {
        "owner": {
          "rules": {},
          "added": true
        },
        "push": {
          "rules": {
            "global:Project-Owners": {
              "action": "ALLOW",
              "force": false,
              "added": true
            }
          },
          "added": true
        }
      },
      "added": true,
      "updatedId": "refs/meta/config"
    }
  },
  "remove": {}
}

```

Bear in mind Admin users will still be able to modify the `refs/meta/config` so they need to be aware of it.

Migration
==

1. Mark gerrit-1 as unhealthy and wait for the open connections to be drained (`ssh -p 29418 admin@localhost gerrit show-queue -q -w`):
`mv $GERRIT_SITE/plugins/healthcheck.jar $GERRIT_SITE/plugins/healthcheck.jar.disabled`
2. Make sure `gerrit.experimentalRollingUpgrade` is set to `true`
3. Stop Gerrit process on gerrit-1
4. Backup git repositories, caches and indexes
5. Upgrade plugins, lib and war file on gerrit-1
6. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.7.2.war init -d $GERRIT_SITE \
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

7. Run project reindex offline. Cconsider increaring memory configuration (`-Xmx<>`) if
the memory allocated is not enough for the reindexing:

```shell
  java -jar <path-to-war-file>/gerrit-3.7.2.war reindex --verbose -d $GERRIT_SITE
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
    [index "accounts_0011"]
	    ready = false
    [index "changes_0077"]
	    ready = false
    [index "groups_0008"]
	    ready = false
    [index "projects_0004"]
	    ready = false
    [index "accounts_0012"]
	    ready = true
    [index "projects_0005"]
	    ready = true
    [index "groups_0009"]
	    ready = true
    [index "changes_0079"]
	    ready = true
  ```

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

9. For **ALL** repositories that have been migrated, listed in the post-migration-push.log,
remove the corresponding `/gerrit/multi-site/<repo>/refs/meta/config` entries in DynamoDb.

10. Start Gerrit
11. Test the node is working fine.
12. Mark gerrit-1 as healthy:
 `mv $GERRIT_SITE/plugins/healthcheck.jar.disabled $GERRIT_SITE/plugins/healthcheck.jar`

Observation period (1 week?)
===

* The multi-site setup allows to run nodes with different versions of the software. Before completing the migration is good practice to leave an observation period, to compare 2 versions running side by side
* Once the observation period is over, and you are happy with the result the migration of the rest of the nodes can be completed
* Keep the migrated node under observation as you did for the other
* Once the migration has been completed for all nodes, revert the block of all projects' configs
`refs/meta/config` for allowing free changes to the configs on any node.

Rollback strategy
===

1. Stop gerrit-X
2. Downgrade plugins, libs and gerrit.war to 3.6.4
3. Downgrade the schema version from 185 to 184 as explained [here](https://www.gerritcodereview.com/3.7.html#downgrade):

*  Shutdown a migrated Gerrit v3.7.x server
*  Downgrade the All-Projects.git version (refname: refs/meta/version) to 184:
    `git update-ref refs/meta/version $(echo -n 184|git hash-object -w --stdin)`

    See git hash-object and git update-ref.

    `NOTE: The migration of the label config to copy-condition performed in v3.7.x init step is idempotent and can be run many times. Also v3.6.x supports the copy-condition and therefore the migration does not need to be downgraded.`

* Run Gerrit v3.6.x init, downgrading all plugins, and run the off-line reindex

    `java -jar gerrit-3.6.x.war init -d site_path`
    `java -jar gerrit-3.6.x.war reindex -d site_path`
* Start Gerrit v3.6.x server

4. Run init on gerrit

        java -jar <path-to>/gerrit-3.6.4.war init -d $GERRIT_SITE \
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

6. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
