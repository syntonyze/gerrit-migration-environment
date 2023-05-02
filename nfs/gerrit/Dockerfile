FROM almalinux:8.5

# Install dependencies
RUN yum -y install \
    git \
    java-11-openjdk \
    procps \
    sudo \
    passwd \
    gettext \
    && yum -y clean all

ENV JAVA_HOME /usr/lib/jvm/jre-11-openjdk

# Add gerrit user
RUN adduser -p -m --uid 1000 gerrit --home-dir /home/gerrit
RUN echo "gerrit:gerrit" | chpasswd
RUN echo "gerrit ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/gerrit && \
    chmod 0440 /etc/sudoers.d/gerrit

# Create gerrit installation directory
RUN mkdir -p /var/gerrit && chown -R gerrit /var/gerrit

ADD --chown=gerrit \
    "https://gerrit-ci.gerritforge.com/job/Gerrit-bazel-stable-3.5/lastSuccessfulBuild/artifact/gerrit/bazel-bin/release.war" \
    /tmp/gerrit.war

COPY --chown=gerrit:gerrit ./plugins/pull-replication.jar /var/gerrit/plugins/pull-replication.jar
COPY --chown=gerrit:gerrit ./plugins/pull-replication.jar /var/gerrit/lib/pull-replication.jar

# Change user
USER gerrit

# Expose ssh and http ports
EXPOSE 29418 8080

COPY --chown=gerrit ./entrypoint.sh /bin

ENTRYPOINT /bin/entrypoint.sh
