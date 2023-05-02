# Run Gerrit with git directory hosted on NFS

This section provides guidance on how to run an NFS setup locally. This can be extremely useful
when troubleshooting gerrit issues which occur when the git directory is hosted on an NFS
filesystem.

## Use case
The desired local setup typically includes running an NFS server, and at least one gerrit container (eg a replica) which 
mounts the NFS-share. The use case we are covering here is a primary/replica setup where replica's git directory
is hosted on NFS, and changes are replicated from primary via http pull-replication. 
Feel free to adapt to your topology if necessary, the principles are the same.

## Background
We are using the `erichough/nfs-server` image mainly because it's easy to use & we had success with it.
The work has been inspired by [this blog post](https://nothing2say.co.uk/running-a-linux-based-nfs-server-in-docker-on-windows-b64445d5ada2).

It is very important to highlight that the **user in both the client and the server needs to be the same**,
otherwise you will hit file ownership problems on any filesystem operation. The server & client(gerrit) dockerfiles
take care of that for you, creating the `gerrit` user and making sure it has the right ownership on the exported
directories.

The containers start with the `privileged` flag set, which is a security risk but necessary to work around
permission issues.

It is worth noting that we are exposing the `/var/gerrit/git` directory as the nfs-share. This is because
more often than not it's the git directory that's shared over the network. You can change this in the
nfs server and gerrit docker files, and (in the static run mode) in the `exports.txt` file.

## Prerequisites
Make sure you change the gerrit version in the [gerrit dockerfile](./gerrit/Dockerfile) and drop your desired version 
of the pull replication jar in the [plugins](./gerrit/plugins) directory.

## NFS Server run modes
There are two different approaches on how to create and access the nfs server for you to choose:
- a [static](./static) IP address assigned to the NFS server (fully automated, but, well, assigns a static IP)
- using the NFS server container's [dynamic](./dynamic) IP address (slightly less automated but using dynamic IP)

### Static IP for the NFS server

To run, simply do
```bash
$ cd nfs/static
$ docker-compose up -d
```

**In detail:**
The Docker Compose YAML file defines a bridge network with the subnet 192.168.1.0/24 
(this allows us to give the NFS Server a known, static IP).

The `addr=192.168.1.2` option (in the `nfs-client-volume` volume) is the reason we need a static IP for the server 
(and hence a configured subnet for the network). Note that using a name (ie. addr=nfs-server) we weren't able to
get the DNS resolution to work properly.

Also in the Docker Compose file we can see that the `nfs-server` container uses a `healthcheck`, this is 
necessary to control when the `nfs-client` will start up (it needs to start after the server is fully up-and-running).
At least on my machine, the nfs-client is too eager to start, and if it starts before the nfs-server is ready,
mounting of the nfs-share will fail.

With the static approach, we are providing an `exports.txt` file, which again utilises the subnet we provided during
the bridge network creation. This file is baked into the image sacrificing a bit of flexibility, but we feel this is 
a small price to pay to have everything automated.

### Dynamic IP for the NFS server
This is slightly more involved, but doesn't tie you to an IP address.

First, build the nfs server image.
```bash
$ cd nfs/dynamic
# for x86 arch
$ docker build -t christophermiliotis/nfs-server .

# for arm arch
$ docker buildx build --platform linux/arm64/v8 -t christophermiliotis/nfs-server -f dockerfile-nfs-server --load .
```

Then, start the nfs server container.
```bash
$ docker run -itd --privileged \
--restart unless-stopped \
-e NFS_EXPORT_0='/var/gerrit/git *(rw,no_subtree_check,insecure)' \
-e NFS_LOG_LEVEL=DEBUG \
-v nfs-server-volume:/var/gerrit/git \
-p 2049:2049 \
christophermiliotis/nfs-server
```

This will start the nfs server, we now need to get the container's IP address so that we can reference it during the 
volume creation:
```bash
# get the container's id
$ docker ps | grep nfs-server
# grab the NFS server container's IP address
$ docker container inspect <nfs-server-id> | grep IPA
```

Now, we can swap the IP address in the Docker Compose file (nfs volume section) with the one from our container:
`o: "addr=<your container ip address here>,rw"`

Finally, we are ready to start up the container.
```bash
$ docker-compose up -d
```

## Check everything is working
If everything works as it should, the gerrit container should be able to start up normally.
For any additional checks, you can log in to the gerrit container and perform some basic file ops:
```bash
$ docker exec -it <container-id> bash
gerrit@replica:/$ df -h
Filesystem        Size  Used Avail Use% Mounted on
:/var/gerrit/git   59G  6.4G   49G  12% /var/gerrit/git

gerrit@replica:/$ touch /var/gerrit/git/foo
```

Then log in to the nfs server and make sure you can see the `foo` file.
```bash
$ docker exec -it <nfs-server-container-id> bash
bash-5.0# ls -lah /var/gerrit/git/
drwxr-xr-x    2 gerrit   gerrit      4.0K May  2 14:52 .
drwxr-xr-x    1 root     root        4.0K May  2 14:29 ..
-rw-r--r--    1 gerrit   gerrit         0 May  2 14:52 foo
```

Then, try to create a repo through the [primary's UI](http://localhost:8080) - you should see the changes eventually 
in the nfs server.

## Stopping & Cleanup
To stop the services, simply run
```bash
$ cd nfs/static
$ docker-compose down --volumes
```

Various files are generated once gerrit is running (eg logs). To clean up once done, or among test runs, 
run the following:
```bash
$ cd nfs
$ git clean -f -d
```