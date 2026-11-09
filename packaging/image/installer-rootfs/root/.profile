# The live system exists only to run the installer. Getty starts it again when it exits.
# The private namespace keeps its mounts out of services, which would otherwise pin the disk for a retry.
exec unshare --mount --propagation private /usr/local/sbin/agentos-install
