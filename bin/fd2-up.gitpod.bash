#!/bin/bash

# Get the path to the main repo directory.
SCRIPT_PATH=$(readlink -f "$0")                     # Path to this script.
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")                # Path to directory containing this script.
REPO_ROOT_DIR=$(builtin cd "$SCRIPT_DIR/.." && pwd) # REPO root directory.

source "$SCRIPT_DIR/lib.bash"
source "$SCRIPT_DIR/colors.bash"

safe_cd "$REPO_ROOT_DIR"

# Ensuring this script is not being run as root.
RUNNING_AS_ROOT=$(id -un | grep "root")
if [ -n "$RUNNING_AS_ROOT" ]; then
  echo -e "${RED}ERROR:${NO_COLOR}The fd2-up.bash script should not be run as root."
  echo "Please run fd2-up.bash without using sudo."
  exit 255
fi

# Ensure that this script is not being run in the development container.
HOST=$(docker inspect -f '{{.Name}}' "$HOSTNAME" 2> /dev/null)
if [ "$HOST" == "/fd2_dev" ]; then
  echo -e "${RED}ERROR:${NO_COLOR} fd2-up.bash script cannot be run in the dev container."
  echo "Always run fd2-up.bash on your host OS."
  exit 255
fi

# Check that /var/run/docker.sock exists and then symlink it as
# ~/.contconf/docker.sock so that it can be mounted the same in WSL.
echo "Checking for docker.sock..."
SYS_DOCKER_SOCK=$(ls /var/run/docker.sock 2> /dev/null)
if [ -z "$SYS_DOCKER_SOCK" ]; then
  echo -e "  ${RED}ERROR:${NO_COLOR} /var/run/docker.sock not found."
  echo "  Ensure that Docker Desktop is installed and running."
  echo "  Also ensure that the 'Allow the default Docker socket to be used'"
  echo "  setting in Docker Desktop -> Settings -> Advanced is enabled."
  exit 255
fi

# Get the name of the directory containing the FarmData2 repo.
# This is the FarmData2 directory by default, but may have been
# changed by the user.
FD2_PATH=$(pwd)
FD2_DIR=$(basename "$FD2_PATH")

# Create the .fd2 directory if it does not exist.
# This directory is used for development environment configuration information.
if [ ! -d ~/.fd2 ]; then
  echo "Creating the ~/.fd2 configuration directory."
  mkdir ~/.fd2
  echo "  The ~/.fd2 configuration directory created."
fi

echo "Configuring Linux  host..."
# We now know this path exists on all platforms.
DOCKER_SOCK_PATH=/var/run/docker.sock
echo "  Using docker socket at $DOCKER_SOCK_PATH."
# If the docker group doesn't exist on the host, create it.
DOCKER_GRP_EXISTS=$(grep "docker" /etc/group)
if [ -z "$DOCKER_GRP_EXISTS" ]; then
  echo "  Creating new docker group on host."
  sudo groupadd docker
  error_check
  DOCKER_GRP_GID=$(grep "^docker:" /etc/group | cut -d':' -f3)
  echo "  docker group created with GID=$DOCKER_GRP_GID."
else
  DOCKER_GRP_GID=$(grep "^docker:" /etc/group | cut -d':' -f3)
  echo "  docker group exists on host with GID=$DOCKER_GRP_GID."
fi

USER_IN_DOCKER_GRP=$(groups | grep "docker")
if [ -z "$USER_IN_DOCKER_GRP" ]; then
  echo "  Adding user $(id -un) to the docker group."
  sudo usermod -a -G docker "$(id -un)"
  error_check
  echo "  User $(id -un) added to the docker group."
  echo "  ***"
  echo "  *** Run the ./fd2-up.bash script again to continue."
  echo "  ***"
  exec newgrp docker
else
  echo "  User $(id -un) is in docker group."
fi

SOCK_IN_DOCKER_GRP=$(ls -lH "$DOCKER_SOCK_PATH" | grep " docker ")
if [ -z "$SOCK_IN_DOCKER_GRP" ]; then
  echo "  Assigning $DOCKER_SOCK_PATH to the docker group."
  sudo chgrp docker $DOCKER_SOCK_PATH
  error_check
  echo "  $DOCKER_SOCK_PATH assigned to docker group."
else
  echo "  $DOCKER_SOCK_PATH belongs to docker group."
fi

# If the docker group does not have write permission to docker.sock add it.
# shellcheck disable=SC2012
DOCKER_GRP_RW_SOCK=$(ls -lH $DOCKER_SOCK_PATH | cut -c 5-6 | grep "rw")
if [ -z "$DOCKER_GRP_RW_SOCK" ]; then
  echo "  Granting docker group RW access to $DOCKER_SOCK_PATH."
  sudo chmod g+rw $DOCKER_SOCK_PATH
  error_check
  echo "  docker group granted RW access to $DOCKER_SOCK_PATH."
else
  echo "  docker group has RW access to $DOCKER_SOCK_PATH."
fi

echo "Configuring FarmData2 group (fd2grp)..."
# If group fd2grp does not exist on host create it
FD2GRP_EXISTS=$(grep "fd2grp" /etc/group)
if [ -z "$FD2GRP_EXISTS" ]; then
  echo "  Creating fd2grp group on host."
  FD2GRP_GID=$(tail -n 1 "$SCRIPT_DIR"/fd2grp.gid)
  FD2GRP_GID_EXISTS=$(grep ":$FD2GRP_GID:" /etc/group)
  if [ -n "$FD2GRP_GID_EXISTS" ]; then
    echo "Attempted to create the fd2grp with GID=$FD2GRP_GID."
    echo "Host machine already has a group with that GID."
    echo "Finding an unused GID for fd2grp."

    desired_gid=$((FD2GRP_GID + 1))
    while true; do
      if ! getent group $desired_gid > /dev/null; then
        break
      fi
      ((desired_gid++))
    done
    FD2GRP_GID=$desired_gid
    echo "  Found unused GID=$FD2GRP_GID for fd2grp."
  fi

  sudo -S groupadd --gid "$FD2GRP_GID" fd2grp
  error_check
  echo "  fd2grp group created on host with GID=$FD2GRP_GID."
else
  FD2GRP_GID=$(getent group fd2grp | cut -d: -f3)
  echo "  fd2grp group exists on host with GID=$FD2GRP_GID."
fi

# If the current user is not in the fd2grp then add them.
USER_IN_FD2GRP=$(groups | grep "fd2grp")
if [ -z "$USER_IN_FD2GRP" ]; then
  echo "  Adding user $(id -un) to the fd2grp group."
  sudo usermod -a -G fd2grp "$(id -un)"
  error_check
  echo "  User user $(id -un) added to the fd2grp group."
  echo "  ***"
  echo "  *** Run the fd2-up.bash script again to continue."
  echo "  ***"
  exec newgrp fd2grp
else
  echo "  User $(id -un) is in fd2grp group."
fi

# If the FarmData2 directory is not in the fd2grp then set it.
# shellcheck disable=SC2010
FD2GRP_OWNS_FD2=$(ls -ld "$FD2_PATH" | grep " fd2grp ")
if [ -z "$FD2GRP_OWNS_FD2" ]; then
  echo "  Assigning $FD2_DIR to the fd2grp group."
  sudo chgrp -R fd2grp "$FD2_PATH"
  error_check
  echo "  $FD2_DIR assigned to the fd2grp group."
else
  echo "  $FD2_DIR is in fd2grp group."
fi

# If the fd2grp does not have RW access to FarmData2 change it.
# shellcheck disable=SC2012
FD2GRP_RW_FD2=$(ls -ld "$FD2_PATH" | cut -c 5-6 | grep "rw")
if [ -z "$FD2GRP_RW_FD2" ]; then
  echo "  Granting fd2grp RW access to $FD2_DIR."
  sudo chmod -R g+rw "$FD2_PATH"
  error_check
  echo "  fd2grp granted RW access to $FD2_DIR."
else
  echo "  fd2grp has RW access to $FD2_DIR."
fi

rm -rf ~/.fd2/gids &> /dev/null
mkdir ~/.fd2/gids
echo "$FD2GRP_GID" > ~/.fd2/gids/fd2grp.gid
echo "$DOCKER_GRP_GID" > ~/.fd2/gids/docker.gid

echo "Removing any stale containers..."
docker rm fd2_postgres &> /dev/null
docker rm fd2_farmos &> /dev/null
docker rm fd2_dev &> /dev/null

echo "Starting containers..."
safe_cd "$FD2_PATH/docker"

# Note: Any command line args are passed to the docker-compose up command
docker compose up -d "$@"

echo "Rebuilding the drupal cache..."
sleep 3 # give site time to come up before clearing the cache.
docker exec -it fd2_farmos drush cr

echo "Waiting for fd2dev container configuration and startup..."
NO_VNC_RESP=$(curl -Is localhost:6901 | grep "HTTP/1.1 200 OK")
if [ "$NO_VNC_RESP" == "" ]; then
  echo -n "  This may take a few moments: "
  wait_for_novnc
  echo ""
fi
echo "  fd2dev container configured and ready."

echo -e "${UNDERLINE_BLUE}FarmData2 development environment started${NO_COLOR}"
