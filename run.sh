#!/bin/bash

load_images() {
  for file in images/*.tar.gz; do
      if [ -f "$file" ]; then
          docker load -i "$file"
      fi
  done
}

create_uuid() {
  local uuid=""
  if command -v uuidgen &>/dev/null; then
      uuid=$(uuidgen)
  else
      if [ -f /proc/sys/kernel/random/uuid ]; then
          uuid=$(cat /proc/sys/kernel/random/uuid)
      else
          uuid="fc72beb0-8bee-4f1f-955c-eceb3a287ecb"
      fi
  fi

  echo $uuid | tr '[:upper:]' '[:lower:]' > ./gateway_conf/apisix.uid
}


wait_for_service() {
  local service=$1
  local url=$2
  local retry_interval=2
  local retries=0
  local max_retry=30

  echo "Waiting for service $service to be ready..."

  while [ $retries -lt $max_retry ]; do
    if curl -k --output /dev/null --silent --head "$url"; then
      echo "Service $service is ready."
      return 0
    fi

    sleep $retry_interval
    ((retries+=1))
  done

  echo "Timeout: Service $service is not available within the specified retry limit."
  return 1
}

validate_api7_ee() {
  wait_for_service api7-ee-dashboard https://127.0.0.1:7443
  wait_for_service api7-ee-gateway http://127.0.0.1:9080
}

output_listen_address() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    ips=$(ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1)
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    ips=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
  fi

  for ip in $ips; do
    echo "API7-EE Listening: Dashboard(https://$ip:7443), Control Plane Address(http://$ip:7900, https://$ip:7943), Gateway(http://$ip:9080, https://$ip:9443)"
  done
  echo "If you want to access Dashboard with HTTP Endpoint(:7080), you can turn server.listen.disable to false in dashboard_conf/conf.yaml, then restart dashboard container"
}

command=${1:-start}

case $command in
    start)
        load_images
        docker compose up -d
        wait_for_service api7-ee-dashboard https://127.0.0.1:7443
        wait_for_service api7-ee-dp-manager http://127.0.0.1:7900
        wait_for_service api7-ee-developer-portal https://127.0.0.1:4321
        api7_registry=$(cat ./.api7_registry)
        api7_registry_namespace=$(cat ./.api7_registry_namespace)
        gateway_image_tag=$(cat ./.gateway_image_tag)
        admin_user="admin:admin"
        status_code=$(curl -s -o /dev/null -w "%{http_code}" -k https://127.0.0.1:7443/api/me -u $admin_user)
        if [[ "${status_code}" == "200" ]]; then
            if [ ! -e "./gateway_conf/apisix.uid" ]; then
                create_uuid
            fi
            image="$api7_registry/$api7_registry_namespace/api7-ee-3-gateway:$gateway_image_tag"
            curl -k -s -u $admin_user "https://127.0.0.1:7443/api/gateway_groups/default/deployment/docker?image=$image&name=api7-ee-gateway-1&http_port=9080&https_port=9443&control_plane_address=https%3A%2F%2Fdp-manager%3A7943&extra_args[]=--network=api7-ee_api7&extra_args[]=-v%20%60pwd%60%2Fgateway_conf%2Fconfig.yaml%3A%2Fusr%2Flocal%2Fapisix%2Fconf%2Fconfig.yaml&extra_args[]=-v%20%60pwd%60%2Fgateway_conf%2Fapisix.uid%3A%2Fusr%2Flocal%2Fapisix%2Fconf%2Fapisix.uid" | bash

            validate_api7_ee
        else
            echo "WARN: admin password has changed. The default gateway instance will not run. You can still create and run the gateway instance later via API7 EE dashboard."
        fi

        echo "API7-EE is ready!"
        output_listen_address
        ;;
    stop)
        docker rm --force api7-ee-gateway-1
        docker compose stop
        ;;
    down)
        docker rm --force api7-ee-gateway-1
        docker compose down
        ;;
    *)
        echo "Invalid command: $command."
        echo "  start: start the API7-EE."
        echo "  stop: stop the API7-EE."
        echo "  down: stop and remove the API7-EE."
        exit 1
        ;;
esac
