#!/usr/bin/env bash

# Helper script to get a docker-compose instance up and running.
#
# Uses docker-compose-developer.yml docker compose file to
#
#   * See if a .env file is available
#   * Using info from .env, be aware of ports and storage names
#   * make sure as much of the services in medic-os are up and running correctly
#   * install valid certificate
#   * show users status of instance
#
# See https://github.com/medic/cht-core/issues/7218 for more info

# shellcheck disable=SC2046
. $(dirname $0)/simple_curses.sh

# todo maybe check to see if docker is running? avoid this error:
# Error response from daemon: dial unix docker.raw.sock: connect: connection refused

# todo MacOS doesn't print simple curses screens at  full width and is stuck at ~80 chars wide?

get_lan_ip() {
  ipInstalled=$(required_apps_installed "ip")
  if [ -n "$ipInstalled" ]; then
    lanAddress=127.0.0.1
  else
    # todo - some of these calls fail wien there's no network connectivity - output stuff it shouldn't:
    #       Device "" does not exist.
    routerIP=$(ip r | grep default | head -n1 | awk '{print $3}')
    subnet=$(echo "$routerIP" | cut -d'.' -f1,2,3)
    if [ -z $subnet ]; then
      subnet=127.0.0
    fi
    lanInterface=$(ip r | grep $subnet | grep default | head -n1 | cut -d' ' -f 5)
    lanAddress=$(ip a s "$lanInterface" | awk '/inet /{gsub(/\/.*/,"");print $2}' | head -n1)
    if [ -z "$lanAddress" ]; then
      lanAddress=127.0.0.1
    fi
  fi
  echo "$lanAddress"
}

get_local_ip_url(){
  lanIp=$1
  cookedLanAddress=$(echo "$lanIp" | tr . -)
  url="https://${cookedLanAddress}.my.local-ip.co:${CHT_HTTPS}"
  echo "$url"
}

required_apps_installed(){
  error=''
  appString=$1
  IFS=';' read -ra appsArray <<<"$appString"
  for app in "${appsArray[@]}"; do
    if ! command -v "$app" &>/dev/null; then
      error="${app} ${error}"
    fi
  done
  echo "${error}"
}

port_open(){
  ip=$1
  port=$2
  # todo - macos prints this on screen. nothing should be shown (like on ubuntu)
  # Connection to 127.0.0.1 port 8443 [tcp/pcsync-https] succeeded!
  nc -z "$ip" "$port"
  echo $?
}

has_self_signed_cert() {
  # todo - when there's no connectivity, this fails w/ DNS
  # curl: (6) Could not resolve host: 127-0-0-1.my.local-ip.co

  # todo - macos returns this error some times
  # curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to 127-0-0-1.my.local-ip.co:8443
  url=$1
  curl --insecure -vvI "$url" 2>&1 | grep -c "self signed certificate"
}

cht_healthy(){
  chtIp=$1
  chtPort=$2
  chtUrl=$3
  portIsOpen=$(port_open "$chtIp" "$chtPort")
  if [ "$portIsOpen" = "0" ]; then
    # todo - when thoere's no connectivity, this fails w/ DNS
    # curl: (6) Could not resolve host: 127-0-0-1.my.local-ip.co

    # todo - macos returns this error some times
    # curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to 127-0-0-1.my.local-ip.co:8443
    http_code=$(curl -k --silent --show-error --head "$chtUrl" --write-out '%{http_code}' | tail -n1)
    if [ "$http_code" != "200" ]; then
      echo "CHT is returning $http_code instead of 200."
    fi
  else
    echo "Port $chtPort is not open on $chtIp"
  fi
}

validate_env_file(){
  envFile=$1
  if [ ! -f "$envFile" ] || [[ ! "$(file $envFile)" == *"ASCII text"* ]]; then
    echo "File not found or not a text file: $envFile"
  else
    # TODO- maybe grep for env vars we're expecting? Blindly including
    # is a bit promiscuous
    # shellcheck disable=SC1090
    . "${envFile}"
    if [ -z "$COMPOSE_PROJECT_NAME" ] || [ -z "$CHT_HTTP" ] || [ -z "$CHT_HTTPS" ]; then
      echo "Missing env value in file: COMPOSE_PROJECT_NAME, CHT_HTTP or CHT_HTTPS"
    elif [[ "$COMPOSE_PROJECT_NAME" =~ [A-Z] ]];then
      echo "COMPOSE_PROJECT_NAME can not have upper case: $COMPOSE_PROJECT_NAME"
    fi
  fi
}

get_running_container_count(){
  result=0
  containers="$1"
  IFS=' ' read -ra containersArray <<< "$containers"
  for container in "${containersArray[@]}"
  do
    if [ "$( docker ps -f name="${container}" | wc -l )" -eq 2 ]; then
        (( result++ ))
    fi
  done
  echo "$result"
}

get_global_running_container_count(){
  # shellcheck disable=SC1083
  if [ "$( docker ps --format={{.Names}} | wc -l )" -gt 0 ]; then
    docker ps --format={{.Names}} | wc -l
  else
    echo "0"
  fi
}

volume_exists(){
  project=$1
  volume="${project}_medic-data"
  if [ "$( docker volume inspect "${volume}" 2>&1  | wc -l )" -eq 2 ]; then
    echo "0"
  else
    echo "1"
  fi
}

get_images_count(){
  images="$1"
  result=0
  IFS=' ' read -ra imagesArray <<< "$images"
  for image in "${imagesArray[@]}"
  do
    if [ "$( docker image ls --format {{.Repository}}:{{.Tag}} | grep -c "${image}" )" -eq 1 ]; then
        (( result++ ))
    fi
  done
  echo "$result"
}

pull_images(){
  images="$1"
  IFS=' ' read -ra imagesArray <<< "$images"
  for image in "${imagesArray[@]}"
  do
    docker image pull "${image}" >/dev/null 2>&1
  done
}

get_docker_compose_yml_path(){
  if [ -f docker-compose-developer.yml ]; then
    echo "docker-compose-developer.yml"
  elif [ -f ../../docker-compose-developer.yml ]; then
    echo "../../docker-compose-developer.yml"
  else
    return 0
  fi
}

docker_up_or_restart(){
  # some times this function called too quickly after a docker change, so
  # we sleep 3 secs here to let the docker container/volume stabilize
  sleep 3

  envFile=$1
  composeFile=$2

  # haproxy never starts on first "up" call, so you know, call it twice ;)
  docker-compose --env-file "${envFile}" -f "${composeFile}" down >/dev/null 2>&1
  docker-compose --env-file "${envFile}" -f "${composeFile}" up -d >/dev/null 2>&1
  docker-compose --env-file "${envFile}" -f "${composeFile}" up -d >/dev/null 2>&1
}

install_local_ip_cert(){
  medicOs=$1
  docker exec -it "${medicOs}" bash -c "curl -s -o server.pem http://local-ip.co/cert/server.pem" >/dev/null 2>&1
  docker exec -it "${medicOs}" bash -c "curl -s -o chain.pem http://local-ip.co/cert/chain.pem" >/dev/null 2>&1
  docker exec -it "${medicOs}" bash -c "cat server.pem chain.pem > /srv/settings/medic-core/nginx/private/default.crt" >/dev/null 2>&1
  docker exec -it "${medicOs}" bash -c "curl -s -o /srv/settings/medic-core/nginx/private/default.key http://local-ip.co/cert/server.key" >/dev/null 2>&1
  docker exec -it "${medicOs}" bash -c "/boot/svc-restart medic-core nginx" >/dev/null 2>&1
}

docker_down(){
  envFile=$1
  composeFile=$2
  docker-compose --env-file "${envFile}" -f "${composeFile}" down >/dev/null 2>&1
}

docker_destroy(){
  project=$1
  containers=$2
  IFS=' ' read -ra containersArray <<<"$containers"
  for container in "${containersArray[@]}"; do
    docker stop -t 0 "${container}" >/dev/null 2>&1
  done
  docker rm "${project}"_haproxy_1 "${project}"_medic-os_1 >/dev/null 2>&1
  docker volume rm "${project}"_medic-data >/dev/null 2>&1
  docker network rm "${project}"_medic-net >/dev/null 2>&1
}

get_cht_version() {
  url=$1
  urlWithPassAndPath="https://medic:password@$(echo "$url" | cut -c 9-9999)/medic/_design/medic "
  # todo - as of 20.04, ubuntu still doesn't actually ship with JQ default :(
  # todo - or maybe just download it for them per https://unix.stackexchange.com/a/649872 ?
  #         but would this work on macos? oh - looks like yes!?
  # "The binaries should just run, but on OS X and Linux you may need to make them executable first using chmod +x jq."
  # - https://stedolan.github.io/jq/download/
  if [ -n "$(required_apps_installed "jq")" ];then
    echo "NA (jq not installed)"
  else
    url=$1
    urlWithPassAndPath="https://medic:password@$(echo "$url" | cut -c 9-9999)/medic/_design/medic "
    version=$(curl -sk "$urlWithPassAndPath"|jq .build_info.base_version | tr -d '"')
    echo "$version"
  fi
}

get_load_avg() {
  # "system_profiler" exists only on MacOS, if it's not here, then run linux style command for
  # load avg.  Otherwise use MacOS style command
  if [ -n "$(required_apps_installed "system_profiler")" ];then
    awk '{print  $1 " " $2 " " $3 }' < /proc/loadavg
  else
    avg=$(sysctl -n vm.loadavg)
    # replace { and } in the output to match linux's output
    echo "${avg//[\}\{]/}"
  fi
}

main (){

  # very first thing check we have valid env file, exit if not
  validEnv=$(validate_env_file "$envFile")
  if [ -n "$validEnv" ]; then
    window "CHT Docker Helper - WARNING - Missing or invalid .env File" "red" "100%"
    append "$validEnv"
    endwin
    set -e
    return 0
  else
    # shellcheck disable=SC1090
    . "${envFile}"
  fi

  # after valid env file is loaded, let's set all our constants
  declare -r APP_STRING="docker;docker-compose;grep;head;cut;tr;nc;curl;file;wc;awk"
  declare -r MAX_REBOOTS=5
  declare -r DEFAULT_SLEEP=$((60 * $((reboot_count + 1))))
  declare -r MEDIC_OS="${COMPOSE_PROJECT_NAME}_medic-os_1"
  declare -r HAPROXY="${COMPOSE_PROJECT_NAME}_haproxy_1"
  declare -r ALL_CONTAINERS="${MEDIC_OS} ${HAPROXY}"
  declare -r ALL_IMAGES="medicmobile/medic-os:cht-3.9.0-rc.2 medicmobile/haproxy:rc-1.17"

  # with constants set, let's ensure all the apps are present, exit if not
  appStatus=$(required_apps_installed "$APP_STRING")
  if [ -n "$appStatus" ]; then
    window "WARNING: Missing Apps" "red" "100%"
    append "Install before proceeding:"
    append "$appStatus"
    endwin
    set -e
    return 0
  fi

  # do all the various checks of stuffs
  volumeCount=$(volume_exists "$COMPOSE_PROJECT_NAME")
  containerCount=$(get_running_container_count "$ALL_CONTAINERS")
  imageCount=$(get_images_count "$ALL_IMAGES")
  globalContainerCount=$(get_global_running_container_count)
  lanAddress=$(get_lan_ip)
  chtUrl=$(get_local_ip_url "$lanAddress")
  health=$(cht_healthy "$lanAddress" "$CHT_HTTPS" "$chtUrl")
  dockerComposePath=$(get_docker_compose_yml_path)
  loadAvg=$(get_load_avg)
  chtVersion="NA"

  # if we're exiting, call down or destroy and quit proper
  if [ "$exitNext" = "destroy" ] || [ "$exitNext" = "down" ] || [ "$exitNext" = "happy" ]; then
    if [ "$exitNext" = "destroy" ]; then
      docker_destroy "$COMPOSE_PROJECT_NAME" "$ALL_CONTAINERS"
    elif [ "$exitNext" = "down" ]; then
      docker_down "$envFile" "$dockerComposePath"
    fi
    set -e
    exit 0
  fi

  # if we're not healthy, report self signed as zero, otherwise if
  # we are healthy, check for self_signed cert and version
  if [ -n "$health" ]; then
    self_signed=0
  else
    chtVersion=$(get_cht_version "$chtUrl")
    self_signed=$(has_self_signed_cert "$chtUrl")
  fi

  # derive overall healthy
  if [ -z "$appStatus" ] && [ -z "$health" ] && [ "$self_signed" = "0" ]; then
    overAllHealth="Good"
  elif [[ "$sleepFor" > 0 ]]; then
    overAllHealth="Booting..."
  else
    overAllHealth="!= Bad =!"
  fi

  # display only action so this paints on bash screen. next loop we'll quit and show nothing new
  if [ "$docker_action" = "destroy" ] || [ "$docker_action" = "down" ]; then
    window "${docker_action}ing ${COMPOSE_PROJECT_NAME} " "red" "100%"
    append "Please wait... "
    endwin
    exitNext=$docker_action
    return 0
  elif [ -z "$docker_action" ] || [ "$docker_action" != "up" ] || [ "$docker_action" = "" ]; then
    set -e
    exit 0
  fi

  # todo - add CHT version as info displayed
  window "CHT Docker Helper: ${COMPOSE_PROJECT_NAME}" "green" "100%"
  append_tabbed "CHT Health - Version|${overAllHealth} - ${chtVersion}" 2 "|"
  append_tabbed "CHT URL|${chtUrl}" 2 "|"
  append_tabbed "FAUXTON URL|${chtUrl}/_utils/" 2 "|"
  append_tabbed "" 2 "|"
  append_tabbed "Project Containers|${containerCount} of 2" 2 "|"
  append_tabbed "Global Containers / Medic Images|${globalContainerCount} / ${imageCount}" 2 "|"
  append_tabbed "Global load Average|${loadAvg}" 2 "|"
  append_tabbed "" 2 "|"
  append_tabbed "Last Action|${last_action}" 2 "|"
  endwin

  if [ -z "$dockerComposePath" ]; then
    window "WARNING: Missing Compose File " "red" "100%"
    append "Download before proceeding: "
    append "wget https://github.com/medic/cht-core/blob/master/docker-compose-developer.yml"
    endwin
    return 0
  fi

  if [[ "$imageCount" -lt 2 ]] && [[ "$sleepFor" = 0 ]]; then
    sleepFor=$DEFAULT_SLEEP
    last_action="Downloading Docker Hub images"
    pull_images "$ALL_IMAGES" &
    (( reboot_count++ ))

    # todo - figure a way to catch the images being successfully downloaded and reset sleepFor=0?
  fi

  if [[ "$volumeCount" = 0 ]] && [[ "$reboot_count" = 0 ]]; then
    sleepFor=$DEFAULT_SLEEP
    last_action="First run of \"up\""
    docker_up_or_restart "$envFile" "$dockerComposePath" &
    (( reboot_count++ ))
  fi

  if [[ "$containerCount" != 2 ]] && [[ "$reboot_count" != "$MAX_REBOOTS" ]] && [[ "$sleepFor" = 0 ]]; then
    sleepFor=$DEFAULT_SLEEP
    last_action="Running \"down\" then  \"up\""
    docker_up_or_restart "$envFile" "$dockerComposePath" &
    (( reboot_count++ ))
  fi

  if [ -n "$health" ] && [[ "$sleepFor" = 0 ]] && [[ "$reboot_count" != "$MAX_REBOOTS" ]]; then
    sleepFor=$DEFAULT_SLEEP
    last_action="Running \"down\" then  \"up\""
    docker_up_or_restart "$envFile" "$dockerComposePath"  &
    (( reboot_count++ ))
  fi

  if [[ "$sleepFor" > 0 ]] && [ -n "$health" ]; then
    window "Attempt number $reboot_count / $MAX_REBOOTS to boot $COMPOSE_PROJECT_NAME" "yellow" "100%"
    append "Waiting $sleepFor..."
    endwin
    (( sleepFor-- ))
  fi

  if [[ "$reboot_count" = "$MAX_REBOOTS" ]] && [[ "$sleepFor" = 0 ]]; then
    window "Reboot max met: $MAX_REBOOTS reboots" "red" "100%"
    append "Please try running docker helper script again"
    endwin
    set -e
    return 0
  fi

  # show health status
  if [ -n "$health" ]; then
    window "WARNING: CHT Not running" "red" "100%"
    append "$health"
    endwin
    return 0
  fi

  # check for self signed cert, install if so
  if [ "$self_signed" = "1" ]; then
    window "WARNING: CHT has self signed certificate" "red" "100%"
    append "Installing local-ip.co certificate to fix..."
    last_action="Installing local-ip.co certificate..."
    endwin
    install_local_ip_cert $MEDIC_OS &
    return 0
  fi

  # reset all the things to be thorough
  sleepFor=0
  reboot_count=0
  last_action=" :) "

  # if we're here, we're happy! Show happy sign and exit next iteration via exitNext
  window "Successfully started ${COMPOSE_PROJECT_NAME} " "green" "100%"
  append "login: medic"
  append "password: password"
  append ""
  append "Have a great day!"
  endwin
  exitNext="happy"

}

main_loop -t .5 $@