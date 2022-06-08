Cut over plan: migration from Gerrit version 3.2.12 to 3.3.11
==

This migration is intended for a single gerrit installation having the following
characteristics:

* Runs 3.2.12
* Runs on an EC2 instance in AWS
* All data (git repositories, caches, databases and indexes) is stored on a
  single EBS volume.

Glossary
==

* `gerrit`: the name of the primary Gerrit instance
* `git repositories`: bare git repositories served by Gerrit stored
  in `gerrit.basePath`
* `caches`: persistent H2 database files stored in the `$GERRIT_SITE/cache`
  directory
* `indexes`: Lucene index files stored in the `$GERRIT_SITE/index` directory
* `gerrit user`: the owner of the process running gerrit
* `$GERRIT_SITE`: environment variable pointing to the base directory of Gerrit
  specified during the `java -jar gerrit.war init -d $GERRIT_SITE` setup command

The described migration plan *will* require downtime. This is due to the fact
that the current installation is not in a highly-available environment since
only one gerrit instance exists.

Once the cutover actions will be reviewed, agreed, tested and measured in
staging, all the operational side of the cutover should be automated to reduce
possible human mistakes.

Pre-cutover
==

* Gerrit 3.3 introduces
  the [Attention Set feature](https://gerrit-documentation.storage.googleapis.com/Documentation/3.3.11/user-attention-set.html)
  . This might change the habitual workflow that gerrit users are familiar with.
  Before this migration happens, users should be given the possibility of
  reading the documentation, asking questions and possibly familiarizing with
  the attention-set in a dedicated environment.

* Gerrit 3.3 introduces a new log timestamp format, which supports both ISO-8601
  and RFC3339. You might be affected if you have any scripts that is parsing the
  timestamp logs with a static format. Check if such scripts/queries exist and
  amend them to parse the new format.

Prerequisites before starting the migration
==

1. Schedule maintenance window to avoid alarms flooding
2. Announce Gerrit upgrade via the relevant channels

Migration and observation
==

1. Run a baseline with the Gatling tests
2. Stop gerrit process
3. Trigger EBS backup from AWS and wait for completion.
4. Upgrade plugins and war file on gerrit:
    - Gerrit 3.3.11 war file can be found in
      the [Gerrit Code Review 3.3 official website](https://gerrit-releases.storage.googleapis.com/gerrit-3.3.11.war)
      . This should be downloaded in a temporary directory (i.e. /tmp/). Note
      that this war file contains also all core plugins. For 3.3 these are:

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

    - Download additional plugins and libraries in the `$GERRIT_SITE/plugins`.
      The latest stable plugins for 3.3 can be found in
      the [GerritForge CI](https://gerrit-ci.gerritforge.com/view/Plugins-stable-3.3/)

6. Run init on gerrit

        java -jar <path-to>/gerrit-3.3.11.war init -d $GERRIT_SITE \
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

   *Note*: that you should remove any core plugin you don't want to install

   The output will be similar to the following:

    ```shell
    Auto-configured "receive.autogc = false" to disable auto-gc after
    git-receive-pack. Auto-configured "protocol.version = 2" to activate git wire
    protocol version 2. Migrating data to schema 184 ...
    ```

This output shows two things of interest:

* The schema upgrade from `183` to `184` (this renames the `Non-Interactive`
  Users group to `Service Users`).

* Disable `receive.autogc` option in `$GERRIT_SITE/etc/jgit.config` (so that no
  gc is executed after receiving data from git-push and updating refs).

* enable git `protocol version 2`, so that gerrit sites benefit from improved
  fetch performance (when enabled by the clients too).

7. Restart gerrit process

8. Run Gatling tests against gerrit
9. Compare and assess the results against the result of the tests executed at
   point 1., and decide whether considering the migration successful or
   rollback.

Rollback strategy
===

1. Stop gerrit
2. Downgrade plugins, libs and gerrit.war to `3.2.12`
3. Downgrade the schema version from 184 to 183.

    ```shell
      cd $GERRIT_SITE/git/All-Projects.git
      echo "*** Current schema version is: "
      git show refs/meta/version # should return 184
      git update-ref refs/meta/version $(echo -n '183' | git hash-object --stdin)
      echo "*** Downgraded schema version is: "
      git show refs/meta/version # should return 183
    ```
4. Revert renaming of `Non-Interactive` users to `Service Users`.

    ```shell
      cd /tmp
      git clone $GERRIT_SITE/git/All-Users.git
      git fetch origin refs/meta/group-names && git checkout FETCH_HEAD
      git revert HEAD
      git push origin HEAD:refs/meta/group-names
    ```

5. Run init on gerrit

        java -jar <path-to>/gerrit-3.2.12.war init -d $GERRIT_SITE \
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

6. Restart gerrit

Disaster recovery
===

1. Stop gerrit
2. Downgrade plugins and gerrit.war to 3.2.12
3. Restore previous indexes, caches, git repositories and DB from the initial
   EBS backup. **NOTE** All data created or modified in Gerrit after the initial
   backup would be lost. This path should therefore taken as __last resort__
   after the rollback strategy has failed and no remediation has been
   identified.
4. Restart gerrit

Notes
==

* All the operations need to be performed in a staging environment first to
  anticipate possible issues happening in production
* All the operations need to be timed to have an idea on how long the whole
  process will take

Useful references
==

[1]: [Gerrit 3.3 documentation](https://www.gerritcodereview.com/3.3.html)

[2]: [Gerrit 3.2 documentation](https://www.gerritcodereview.com/3.2.html)

[3]: [Plugins artifacts](https://gerrit-ci.gerritforge.com/)

[4]: [Attention set](https://gerrit-documentation.storage.googleapis.com/Documentation/3.3.11/user-attention-set.html)