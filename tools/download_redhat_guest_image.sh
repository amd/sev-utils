#!/bin/bash

# export environment variable
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
source "$HOME/.bash_profile"
REDHAT_OFFLINE_TOKEN="${REDHAT_OFFLINE_TOKEN}"
WORKING_DIR="${WORKING_DIR:-$HOME/snp}"
LAUNCH_WORKING_DIR="${LAUNCH_WORKING_DIR:-${WORKING_DIR}/launch}"
GUEST_NAME="${GUEST_NAME:-snp-guest}"
IMAGE="${IMAGE:-${LAUNCH_WORKING_DIR}/${GUEST_NAME}/${GUEST_NAME}.qcow2}"
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------

#  variables shared across multiple functions
access_token=$(curl https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token -d grant_type=refresh_token -d client_id=rhsm-api -d refresh_token=$REDHAT_OFFLINE_TOKEN | jq -r '.access_token')
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------

save_rhel_download_options(){
    local system_architecture=$(arch)

    # Make the API request and store the response in a filename
    local downloads_api_response=$(curl -H "Authorization: Bearer $access_token" "https://api.access.redhat.com/management/v1/images/rhel/${1}/${system_architecture}")

    # Parse the JSON and store it in another filename
    local parsed_data=$(echo "$downloads_api_response" | jq '.')

    # save it in a file
    echo "$parsed_data" > "$2"
}

download_rhel_guest_image(){
    local rhel_cloud_init_img_url=$(echo "$1"| jq '.downloadHref')
    local rhel_cloud_init_img_url=$(echo "${rhel_cloud_init_img_url}" | tr -d '"')

    # Download the qcow2 file using download RedHat API
    local image=$(curl -H "Authorization: Bearer $access_token" "$rhel_cloud_init_img_url")

    local url=$(echo $image | jq -r .body.href)
    curl $url -o "$2"
}

search_and_download_redhat_guest_image(){
    local redhat_version=$(cat  /etc/os-release | grep VERSION_ID) #Returns VERSION_ID="<X.X>"
    local redhat_version=$(echo "${redhat_version//"VERSION_ID="/''}" | tr -d '"')  # Removes "VERSION_ID=" from "VERSION_ID=<X.X>"

    local save_rhel_downloads_folder=$(realpath "${LAUNCH_WORKING_DIR}/${GUEST_NAME}")
    local basefile="rhel-downloads-${redhat_version}.json"
    local rhel_available_downloads_json="${save_rhel_downloads_folder}/${basefile}"

    # Save all available RHEL <X.X> file downloads into json file 
    if [ ! -f "$rhel_available_downloads_json" ]; then
        save_rhel_download_options "$redhat_version" "$rhel_available_downloads_json"

    fi
    
    # Search for KVM Guest Image json object
    local all_files_available_for_dwnld=$(cat "$rhel_available_downloads_json" |  jq '.body')
    local rhel_guest_img_object=$(jq '.[] | select(.imageName | test("Guest Image"))' <<< "$all_files_available_for_dwnld")
    
    # Download RedHat qcow2 image file if not present
    if [ ! -f "$IMAGE" ]; then  
        download_rhel_guest_image "$rhel_guest_img_object" "$IMAGE"
    fi
}

search_and_download_redhat_guest_image

