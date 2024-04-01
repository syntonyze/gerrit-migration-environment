Cut over plan: migration from Gerrit version 3.4.5 to 3.9.2
==

This migration is intended for a single primary and multiple Gerrit replicas.

**NOTE:**
* The cutover will require a downtime of the system that will have to be assessed
during the testing in staging
* It won't be possible to roll back from 3.9 to 3.4

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

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

*NOTE*: the following instructions describe a migration for Gerrit running in a mutable installation.
When using Docker, immutable images will need to be created, reflecting configuration and
software versions described.

Breaking changes and important notes:
==

* Repo download scheme has been renamed to [repo](https://www.gerritcodereview.com/3.5.html#breaking-changes)

* The ignore feature is completely removed from Gerrit’s web app;
  the ignore and unignore actions and the associated is:ignored predicate
  are not supported [anymore](https://www.gerritcodereview.com/3.6.html#breaking-changes).
  Asses automation scripts that might use the predicate.

* Enhance metric name sanitize function to remove collision on ‘_’ between metrics.

  Collision between the sanitized metric names can be easily created e.g. foo_bar will collide with foo+bar.
  In order to avoid collisions keep the rules about slashes and replace not supported chars
  with _0x[HEX CODE]_ string. The replacement prefix 0x is prepended with another replacement
  prefix.

  Make sure you won't be affected by metrics renaming.

* `refreshAfterWrite` and `maxAge` settings in gerrit
config are now honored for both persistent and in-memory caches. Previously these settings were erroneously ignored for persistent caches

* Assignee feature is completely removed from the Gerrit UI

* Prolog rules have been [deprecated](https://www.gerritcodereview.com/3.6.html#submit-requirements) in favour of [submit requirements](https://gerrit-documentation.storage.googleapis.com/Documentation/3.6.6/config-submit-requirements.html)

* Project Owners implicit delete reference permission has been [removed](https://www.gerritcodereview.com/3.6.html#breaking-changes).
Before this release all Project Owners had implicit delete permission to all refs unless
force-push was blocked for the user.
Admins that are relying on previous behavior or wish to maintain it for their users
can simply add the permission explicitly in All-Projects:
```
        [access "refs/*"]
            delete = Project Owners
```

*NOTE*: If you choose to do so, blocking force-push no longer has any effect on permission to
delete refs by means other than git (REST, UI).

* Support for CentOS is dropped and the base image replaced by AlmaLinux

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

* Disallow uploading new prolog rules files. Clients should use
submit-requirements instead. Please note that modifications and deletions of
existing rules.pl files are still allowed.

* There are new limit definitions which can be used to protect Gerrit from improper client activity:
 * `change.topicLimit`: defines the maximum number of changes in the same topic
 * `change.maxFileSizeDownload`: prevents memory overload caused by clients
 downloading large files from REST-API
 * `change.maxFileSizeDiff`: prevents memory overload caused by rendering large
 files diffs in a browser

* `index.indexChangesAsync`:  reindex changes with an asynchronous process when a
change is updated from the UI. The new option yields a much more responsive user-experience
by releasing UI elements without waiting for the backend reindex execution to complete

* `core.usePerRequestRefCache` setting, true by default, introduced a per request
(currently per request thread) ref cache, helping reduce the overhead of checking
if the packed-refs file was outdated. However, in some scenarios, such as multi-site or
concurrency between git-receive-pack and git-gc, it may lead to split-brain
inconsistencies and, in the worst-case scenario, to the corruption of the
underlying repository. Set it to `false`.

Pre-cutover preparation tasks 3.5
==

* Java >= 11.0.10 is needed. Support for [Java 8 has been dropped](https://www.gerritcodereview.com/3.5.html#support-for-java-8-dropped)

* Download new war file: Gerrit 3.5.6-46-gXXXX will be provided by GerritForge.

Prerequisites before starting the migration
==

1. Run 3.4 "acceptance tests" baseline
 * Define a test plan with acceptance criteria for the migration to be succesfull, including:
   * functional tests results
   * client-side performance
   * server-side performance

*NOTE:* We suggest using [Gatling](https://gatling.io/) to automate tests and compare performance between releases. [Here](https://github.com/GerritForge/gatling-sbt-gerrit-test)
an example of test suite. This suite is just an example and doesn't provide an exhaustive
test coverage.
 * Run a baseline against Gerrit 3.4 and record the results

2. Schedule maintenance window to avoid alarms flooding
3. Announce Gerrit upgrade via the relevant channels

Migration
==

This cutover plan will first migrate the primary instance and then the replicas.

1. Stop Gerrit process on gerrit primary
2. Backup git repositories, caches and indexes
3. Set:
  *  `index.paginationType` [pagination type](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#index) to `NONE`
  *  `index.cacheQueryResultsByChangeNum` [flag](https://gerrit-review.googlesource.com/Documentation/config-gerrit.html#index.cacheQueryResultsByChangeNum)
to `false`
  * `core.usePerRequestRefCache` to `false`
4. Upgrade war file on Gerrit primary
5. Disable all plugins
6. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.5.6-46-gbeae5f2021.war init -d $GERRIT_SITE --batch
```

6. Run `copy-approvals`:

```shell
java -jar $GERRIT_SITE/bin/gerrit.war copy-approvals -d $GERRIT_SITE
```

Check [gerrit copy-approvals](https://gerrit-documentation.storage.googleapis.com/Documentation/3.5.2/cmd-copy-approvals.html)
to get more information.

Pre-cutover preparation tasks 3.6
==

* Download new war file: Gerrit 3.6.8-46-gXXXX will be provided by GerritForge.

Migration
==

1. Upgrade war file on Gerrit primary
2. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.6.8-XXX.war init -d $GERRIT_SITE --batch
```

Pre-cutover preparation tasks 3.7.8
==

* Download new Gerrit 3.7.8 war file from the
  [Gerrit Code Review 3.7 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.7.8.war).

Migration
==

1. Upgrade war file on Gerrit primary
2. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.7.8.war init -d $GERRIT_SITE --batch
```

Pre-cutover preparation tasks 3.8.4
==

* Download new Gerrit 3.8.4 war file from the
  [Gerrit Code Review 3.8 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.8.4.war).

Migration
==

1. Upgrade war file on Gerrit primary
2. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.8.4.war init -d $GERRIT_SITE --batch
```

Pre-cutover 3.9.2
==

* Java 17 is the JVM version for running Gerrit in production

* Download new Gerrit 3.9.2 war from the
  [Gerrit Code Review 3.9 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.9.2.war).
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

    - Download additional plugins and libraries from [GerritForge CI](https://gerrit-ci.gerritforge.com/plugin-manager/)

 * Make sure custom plugins are compatible with the new Gerrit version

Migration
==

This cutover plan will first migrate the primary instance and then the replicas.

1. Upgrade non-core plugins, lib and war file on Gerrit primary
2. Make sure all the plugins are correctly enabled
 *NOTE:* The [owners plugin](https://gerrit.googlesource.com/plugins/owners/) in particular
   influences the overall submit requirements result  
3. Run init on Gerrit:

```shell
  java -jar <path-to-war-file>/gerrit-3.9.2.war init -d $GERRIT_SITE \
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

3. Run an offline re-indexing:

```shell
cd $GERRIT_SITE && \
java -jar <path-to-war-file>/gerrit-3.9.2.war reindex -d .
```

Once reindexing will be over, in the `$GERRIT_SITE/index/gerrit_index.config`
you should have the following:

  ```shell
  [index "accounts_0013"]
    ready = true
  [index "groups_0010"]
    ready = true
  [index "changes_0084"]
    ready = true
  [index "projects_0008"]
    ready = true
  ```

4. Restart Gerrit

```shell
cd $GERRIT_SITE && \
./bin/gerrit.sh start
```

5. On all the replicas:
  * replicate all the git data for all the repositories
  * replace the gerrit war file
  * run an offline reindex:
```shell
cd $GERRIT_SITE && \
java -jar <path-to-war-file>/gerrit-3.9.2.war reindex -d .
```
  * restart Gerrit
```shell
cd $GERRIT_SITE && \
./bin/gerrit.sh start
```

6. Run the "acceptance tests" against Gerrit 3.9 and compare the results:
 * If everything is ok, continue with the replicas migration
 * If there are concerns:
  * consider rolling back
  * assess the issues and plan the changes needed before the next migration
  * re-run the migration plan

Rollback strategy
===

There is no rollback. The only way of going back to 3.4 is restoring the
system from a consistent backup of git data, indexes and caches.

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* The testing has to be done with a staging environment as close as possible
  to the production one in term of specs, data type and amount, traffic
* The upgrade needs to be performed with traffic on the system
* Full release notes can be found here:
  * https://www.gerritcodereview.com/3.5.html
  * https://www.gerritcodereview.com/3.6.html
  * https://www.gerritcodereview.com/3.7.html
  * https://www.gerritcodereview.com/3.8.html
  * https://www.gerritcodereview.com/3.9.html