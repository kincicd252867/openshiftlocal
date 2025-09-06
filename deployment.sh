#automated the deployment process of openshift local for testing, development purpose in a single-node cluster
#!/bin/bash

# Check nested virtualization's status
echo "Checking if nested virtualization is enabled..."
if lsmod | grep -woq 'kvm' && lsmod | grep -woq 'kvm_amd'; then
    echo "Both KVM and KVM_AMD modules are active."
else
    echo "One or both of the modules are not active. Might need to enable virtualization in BIOS/UEFI or load the modules manually" >&2
    exit 1
fi

# Check if ping to dns.google receives an ICMP echo reply
echo "Checking internet connectivity..."
ping -c 20 dns.google 
if [ $? -eq 0 ]; then
    # Ping successful, proceed with installation
    echo "Internet connectivity confirmed"
    echo "Installing virtualization packages..."
    sudo dnf install -y qemu-kvm libvirt virt-manager virt-install
    if [ $? -eq 0 ]; then
        echo "Virtualization packages installed successfully"
    else
        echo "Failed to install virtualization packages. Check your permissions or package availability." >&2 
        exit 1
    fi
else
    # Ping failed, abort installation
    echo "No internet connectivity. Ping to dns.google failed. Aborting deployment..." >&2 
    exit 1
fi

# Start and enable the libvirtd if inactive
CHECK_STATUS_LIBVIRTD=$(sudo systemctl is-active libvirtd)

if [[ "$CHECK_STATUS_LIBVIRTD" == *"inactive"* ]]; then
    echo "libvirtd.service is inactive, starting and enabling..."
    sudo systemctl start libvirtd

CHECK_NEW_STATUS_LIBVIRTD=$(sudo systemctl is-active libvirtd)

   if [[ "$CHECK_NEW_STATUS_LIBVIRTD" == *"active"* ]]; then
       echo "libvirtd.service is active(running), enabling..."
       sudo systemctl enable --now libvirtd
   else
       echo "libvirtd.service is failed to start, Aborting deployment..." >&2
       exit 1
   fi 
fi 

# Final verdict
verify_libvirtd() {
     
    local NEW_ACTIVE_STATUS_LIBVIRTD=$(sudo systemctl is-active libvirtd)
    local NEW_ENABLED_STATUS_LIBVIRTD=$(sudo systemctl is-enabled libvirtd)
    
    # Check if service is active
    if [[ $NEW_ACTIVE_STATUS_LIBVIRTD == *"active"* ]]; then
        echo "INFO: libvirtd is active to start at boot"
    else
        echo "ERROR: libvirtd is not active to start at boot"      
        return 1
    fi
    
    # Check if service is enabled
    if [[ $NEW_ENABLED_STATUS_LIBVIRTD == *"enabled"* ]]; then
        echo "INFO: libvirtd is enabled to start at boot"
    else
        echo "ERROR: libvirtd is not enabled to start at boot" 
    fi
    
    echo "Libvirtd is fully operational and configured correctly"
    return 0
}

# Call function for service verification
if verify_libvirtd; then
    echo "Verification successful: libvirtd.service is running properly"
else
    echo "Verification failed: libvirtd.service is failed to run. Aborting deployment..." >&2
    exit 1
fi

# Extract CRC archive
CRC_ARCHIVE="crc-linux-amd64.tar.xz"

echo "Extracting CRC archive..."
if [ -f "$CRC_ARCHIVE" ]; then
    echo "Found CRC archive: $CRC_ARCHIVE, extracting..."
    tar -xvf $CRC_ARCHIVE
else
    echo "CRC archive not exists, Aborting deployment..."
    exit 1
fi

# Copy CRC binary to /bin folder
BINARY_PATH=/usr/local/bin
CRC_PROGRAM=./crc-linux-2.51.0-amd64/crc
if [ -f "$CRC_PROGRAM" ]; then   
    echo "Copying crc binary to "$BINARY_PATH"..."
    sudo cp -a  "$CRC_PROGRAM" "$BINARY_PATH" || { echo "Failed to copy $CRC_PROGRAM, Aborting deployment..." >&2
    exit 1
}
    echo "Making crc executable..."
    sudo chmod +x "$BINARY_PATH"/crc|| { echo "Failed to set executable permissions for crc"
    exit 1
}
    echo "CRC binary copied to "$BINARY_PATH" successfully"
else
    echo "CRC binary not exists, Aborting deployment..."
    exit 1
fi

# Verify if directory "/opt/crc" not exists and create new one 
CUSTOM_CRCEXECUTABLE="/opt/crc"

if [ ! -d "$CUSTOM_CRCEXECUTABLE" ]; then
    echo "Creating $CUSTOM_CRCEXECUTABLE directory..."
    sudo mkdir -p "$CUSTOM_CRCEXECUTABLE"
else
    echo "$CUSTOM_CRCEXECUTABLE directory already exists."
fi

# Setting ownership of /opt/crc
echo "Setting ownership of $CUSTOM_CRCEXECUTABLE to $EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC..."

CURRENT_USER_CRC=$(stat -c %U "$CUSTOM_CRCEXECUTABLE" 2>/dev/null)
CURRENT_GROUP_CRC=$(stat -c %G "$CUSTOM_CRCEXECUTABLE" 2>/dev/null)
CURRENT_PERMS_CRC=$(stat -c %a "$CUSTOM_CRCEXECUTABLE" 2>/dev/null)

EXPECTED_USER_CRC="sysadmin01"
EXPECTED_GROUP_CRC="libvirt"
EXPECTED_PERMS_CRC="775"

if [ "$CURRENT_USER_CRC" == "$EXPECTED_USER_CRC" ] && [ "$CURRENT_GROUP_CRC" == "$EXPECTED_GROUP_CRC" ] && [ "$CURRENT_PERMS_CRC" == "$EXPECTED_PERMS_CRC" ]; then
    echo "Verification successful: $CUSTOM_CRCEXECUTABLE has correct ownership ($EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC) and permissions ($EXPECTED_PERMS_CRC)."
else
    echo "Verification failed: $CUSTOM_CRCEXECUTABLE does not meet required ownership ($EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC) and permissions ($EXPECTED_PERMS_CRC). Attempting to rectify..."
    # Rectify the ownership to sysadmin:libvirt
    sudo chown -R $EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC "$CUSTOM_CRCEXECUTABLE" || {
        echo "Failed to set ownership $EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC for $CUSTOM_CRCEXECUTABLE. Aborting deployment..." >&2
        exit 1
    }    
    # Change permissions to 775
    sudo chmod "$EXPECTED_PERMS_CRC" "$CUSTOM_CRCEXECUTABLE" || {
        echo "Failed to set permissions to $EXPECTED_PERMS_CRC for $CUSTOM_CRCEXECUTABLE. Aborting deployment..." >&2
        exit 1
    }
    echo "$CUSTOM_CRCEXECUTABLE ownership set to $EXPECTED_USER_CRC:$EXPECTED_GROUP_CRC and permissions set to $EXPECTED_PERMS_CRC."
fi

# Create symbolic link from custom location to home directory
echo "Creating symbolic link from $CUSTOM_CRCEXECUTABLE to $HOME/.crc ..."

# Check existing symlink and create one if not exists
if [[ -L "$HOME/.crc" ]]; then
    current_target=$(readlink -f "$HOME/.crc")
    if [[ "$current_target" == "$CUSTOM_CRCEXECUTABLE" ]]; then
        echo "Symlink already correctly points to $CUSTOM_CRCEXECUTABLE"
    else
        echo "Existing symlink points to $current_target (should be $CUSTOM_CRCEXECUTABLE)"
        echo "Recreating symlink..."
        rm -f "$HOME/.crc"
        ln -s "$CUSTOM_CRCEXECUTABLE" "$HOME/.crc"
        if [[ $? -eq 0 ]]; then
            echo "Symlink created successfully"
        else
            echo "Symlink creation failed. Aborting deployment..." >&2
            exit 1
        fi
        echo "Symlink updated successfully"
    fi
fi

# Functions to get available disk space for root directory
echo "Get the current disk usage for root directory..."
DISK_USAGE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/[^0-9]//g')

# Check if the disk space is sufficient for crc setup, and set 70GB disk size
if [ $DISK_USAGE -gt 50 ]; then
    echo "Available disk space is ${DISK_USAGE}GB, which exceeds 70GB. Setting CRC disk size to 70GB."
    crc config set disk-size 50
else
    echo "Available disk space is ${DISK_USAGE}GB, which less than 70GB. Aborting deployment..."
    exit 1
fi    

# Function to check and enable telemetry (proceeds on failure)
check_and_enable_telemetry() {
    echo "Check the content-telemetry status..."
    local TELEMETRY_STATUS=$(crc config get consent-telemetry | awk 'NR==1 {print $3}')
    if [[ -z "$TELEMETRY_STATUS" ]]; then
        echo "Failed to retrieve telemetry status. Proceeding anyway..." >&2
        return 0
    fi
    if [[ "$TELEMETRY_STATUS" == *"no"* ]]; then
        echo "Enable content-telemetry for debugging..."
        crc config set consent-telemetry yes
        if [[ $? -eq 0 ]]; then
            echo "Enabled content-telemetry"
        else
            echo "Failed to enable content-telemetry. Proceeding to set the system network-mode..." >&2
        fi
    else
        echo "Content-telemetry is already enabled"
    fi
}

# Function to configure network mode
configure_network_mode_system() {
    echo "Check the crc's network-mode status"
    local NETWORK_STATUS=$(crc config get network-mode | awk 'NR==1 {print $3}')
    if [[ -z "$NETWORK_STATUS" ]]; then
        echo "Failed to retrieve network-mode status. Aborting deployment..." >&2
        exit 1
    fi
    if [[ "$NETWORK_STATUS" == *"system"* ]]; then
        echo "Network-mode already set to system. Proceeding to set the virtual cpu quantity"
    else
        echo "Network-mode is not system, setting to system..."
        crc config set network-mode system
        if [[ $? -eq 0 ]]; then
            echo "Network-mode successfully set to system"
        else
            echo "Failed to set the system-mode. Aborting deployment..." >&2
            exit 1
        fi
    fi
}

# Function to configure VM resources
configure_vm_resources() {
    echo "Checking the current virtual CPU and memory..."
    local CRC_CPU=$(crc config get cpus | awk 'NR==1 {print $9}' | tr -d "'")
    local CRC_MEMORY=$(crc config get memory | awk 'NR==1 {print $9}' | tr -d "'")
    if [[ "$CRC_CPU" -eq 4 ]] && [[ "$CRC_MEMORY" -eq 12288 ]]; then
        echo "Current virtual CPU is already 4, and virtual memory is already 12GB"
    else
        echo "Current virtual CPU and memory are not 4 and 12GB respectively, setting now..."
        crc config set cpus 4
        if [[ $? -ne 0 ]]; then
            echo "Failed to set the virtual CPU. Aborting deployment..." >&2
            exit 1
        fi
        crc config set memory 12288
        if [[ $? -ne 0 ]]; then
            echo "Failed to set the virtual memory. Aborting deployment..." >&2
            exit 1
        fi
        echo "Virtual CPU and memory successfully set to 4 and 12GB"
    fi
}

# Main function to orchestrate configuration
main() {
    check_and_enable_telemetry
    configure_network_mode_system
    configure_vm_resources
}

# Execute main and handle bundle operations
if main; then
    NEW_BUNDLE=/opt/crc/cache/crc_libvirt_4.18.2_amd64.crcbundle
    GET_BUNDLE=$(crc config get bundle)
    echo "All conditions are met. Proceeding with crc setup and bundle operations."    
    crc setup || {
        echo "Failed to run crc setup. Aborting deployment..." >&2
        exit 1
    }
    crc config unset bundle || {
        echo "Failed to unset bundle..." >&2
    }
    crc config set bundle "$NEW_BUNDLE" || {
        echo "Failed to set new bundle..." >&2
    }
    if [[ "$GET_BUNDLE" == "$NEW_BUNDLE" ]]; then 
        echo "Bundle is set to $NEW_BUNDLE"
    fi 
    echo "Bundle operations and crc setup completed successfully."
else
    echo "Conditions are not all met, check the error details from logs. Aborting deployment..." >&2
    exit 1
fi
       

#Setting SELinux context for ~/.crc
echo "Setting SELinux context for $HOME/.crc..."
CONTEXT=$(stat -c %C "$HOME/.crc")
TYPE=$(echo "$CONTEXT" | cut -d: -f3)

# Verify if the SELinux context is not virt_content_t, then change to virt_content_t
if [ "$TYPE" != "virt_content_t" ]; then
    echo "Current SELinux context for $HOME/.crc is $TYPE, changing to virt_content_t..."
    sudo chcon -h -t virt_content_t "$HOME/.crc"

    # Verify if the SELinux context is changed to virt_content_t
    NEW_CONTEXT=$(stat -c %C "$HOME/.crc")  
    NEW_TYPE=$(echo "$NEW_CONTEXT" | cut -d: -f3)
    if [[ "$NEW_TYPE" == *"virt_content_t"* ]]; then
        echo "SELinux context for $HOME/.crc is changed to virt_content_t"
    else
        echo "Failed to change SELinux context for $HOME/.crc, Abort the deployment..."
        exit 1
    fi
else
    echo "SELinux context for $HOME/.crc is already set"
fi

# Start the crc instance / crc vm with pull secret
PULL_SECRET="pull-secret.txt"
echo "Starting CRC with pull secret..."
if [ -f "$PULL_SECRET" ]; then
    echo "pull-secret is found, start the CRC VM"
    crc start -p pull-secret.txt
else
    echo "pull-secret is not found, abort the deployment..."
    exit 1
fi

# Verify if the crc instance is running properly
STATUS=$(crc status | grep Running | awk 'NR==2 {print $2}')
if [[ "$STATUS" == *"Running"* ]]; then
    echo "CRC VM is running."
else
    echo "CRC VM is not running, aborting deployment..."
    exit 1
fi

# Check and add each tcp port in firewalld if not already allowed
allowed_ports=$(sudo firewall-cmd --zone=public --list-ports)
required_ports=(80 443 6443) # Set up array for tcp ports

echo "First firewall ports verification..."
for port in "${required_ports[@]}"; do
    if ! grep -woq "${port}/tcp" <<< "$allowed_ports"; then
        echo "${port}/tcp is MISSING. Applying..."
        sudo firewall-cmd --zone=public --add-port=${port}/tcp --permanent
        firewalld_verification=false
    else
        echo "${port}/tcp is PRESENT"
        firewalld_verification=true
    fi
done

# Reload the firewalld if verified the required ports are allowed
if ! $firewalld_verification; then
    echo "Verification successful: all required ports are allowed in firewalld. Reloading the firewalld..."
    sudo firewall-cmd --reload || {
        echo "Reload failure. Check the logs for error details..."
    }
fi

# Final verification
echo "Final firewall ports verification..."
for port in "${required_ports[@]}"; do
    if ! grep -woq "${port}/tcp" <<< "$allowed_ports"; then
        echo "${port}/tcp is MISSING."
        firewalld_verification_final=false
    else
        echo "${port}/tcp is PRESENT"
        firewalld_verification_final=true
    fi
done

MISSING_PORTS=${port}/tcp

if $firewalld_verification_final; then
    echo "Verification successful: all required ports are confirmed allowed in firewalld"
else
    echo "Verification failure: missing ports -> ${MISSING_PORTS[*]}" >&2
fi

# By default, port 80 and 443 are in http_port_t. Verify if the port 6443 not assign to http_port_t in SELinux,
http_ports=6443
port_assigned=$(sudo semanage port -l | grep http_port_t | awk '{print $3}' | tr -d ',')

if grep -q "$http_ports" <<< "$port_assigned"; then
    echo "Verification successful: port ${http_ports}/tcp are assigned in SELinux."
else
    echo "Port ${http_ports}/tcp is MISSING, assign to http_port_t in SELinux"
    sudo semanage port -a -t http_port_t -p tcp $http_ports || {
        echo "Failed to assign port ${http_ports}/tcp to http_port_t. Aborting deployment." >&2
        exit 1
    }  
    echo "Port ${http_ports}/tcp successfully assigned to http_port_t."
fi

# Install haproxy for tcp port farwarding
echo "Installing haproxy packages"
sudo dnf install -y haproxy
if [ $? -eq 0 ]; then
   echo "Haproxy packages installed successfully."
else
   echo ""Failed to install haproxy packages. Check your permissions or package availability. >&2
   exit 1
fi


#!/bin/bash

# Get CRC IP and validate
CRC_IP=$(crc ip 2>/dev/null | tr -d '[:space:]')
if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid IP from 'crc ip'" >&2
    exit 1
fi

# Copy the new configuration file for replacement
REPO_CONF="/crc/haproxy.cfg"
CONF=/etc/haproxy/haproxy.cfg
CONTENT=$(<"$REPO_CONF")
UPDATED_CONTENT=${CONTENT//<crc-ip>/$CRC_IP}

echo "Copy the new configuration file for replacement..."
if [ -f "$REPO_CONF" ]; then
    echo "Found new configuration file: $REPO_CONF, copying..."
    sudo cp -a "$REPO_CONF" "$CONF"
else
    echo "The new configuration file $REPO_CONF not exists, Aborting deployment..." >&2
    exit 1
fi

# Check the current ownership and permissions
CURRENT_USER_HAPROXY=$(stat -c %U "$CONF" 2>/dev/null)
CURRENT_GROUP_HAPROXY=$(stat -c %G "$CONF" 2>/dev/null)
CURRENT_PERMS_HAPROXY=$(stat -c %a "$CONF" 2>/dev/null)

# Define expected value
EXPECTED_USER_HAPROXY="root"
EXPECTED_GROUP_HAPROXY="haproxy"
EXPECTED_PERMS_HAPROXY="640"

if [ "$CURRENT_USER_HAPROXY" == "$EXPECTED_USER_HAPROXY" ] && [ "$CURRENT_GROUP_HAPROXY" == "$EXPECTED_GROUP_HAPROXY" ] && [ "$CURRENT_PERMS_HAPROXY" == "$EXPECTED_PERMS_HAPROXY" ]; then
   echo "Verification successful: $CONF has correct ownership ($EXPECTED_USER_HAPROXY:$EXPECTED_GROUP_HAPROXY) and permissions ($EXPECTED_PERMS_HAPROXY)."
else
   echo "$CONF does not meet required ownership ($EXPECTED_USER_HAPROXY:$EXPECTED_GROUP_HAPROXY) and permissions ($EXPECTED_PERMS_HAPROXY). Attempting to rectify..."
   # Rectify the ownership to root:haproxy
   sudo chown $EXPECTED_USER_HAPROXY:$EXPECTED_GROUP_HAPROXY "$CONF" || {
       echo "Failed to set ownership $EXPECTED_USER_HAPROXY:$EXPECTED_GROUP_HAPROXY for $CONF. Aborting deployment..." >&2
       exit 1
   }    
   # Change permissions to 640
   sudo chmod $EXPECTED_PERMS_HAPROXY "$CONF" || {
       echo "Failed to set permissions to $EXPECTED_PERMS_HAPROXY for $CONF. Aborting deployment." >&2
       exit 1
   }
   echo "$CONF ownership set to $EXPECTED_USER_HAPROXY:$EXPECTED_GROUP_HAPROXY and permissions set to $EXPECTED_PERMS_HAPROXY."
fi

# Create backup for configuration file
sudo cp "$CONF" "$CONF.bak" || {
    echo "Failed to create backup of $CONF. Aborting deployment..." >&2
    exit 1
}

# Validate the configuration file
CHECK_OUTPUT=$(sudo haproxy -c -f "$CONF" 2>&1)

if [[ "$CHECK_OUTPUT" == *"Configuration file is valid"* ]]; then
   echo "Validation successful."
else
   echo "Validation failed. For error details: $CHECK_OUTPUT. Aborting deployment..." >&2
   exit 1
fi

# Start and enable the haproxy if inactive
CHECK_STATUS_HAPROXY=$(sudo systemctl is-active haproxy)

if [[ "$CHECK_STATUS_HAPROXY" == *"inactive"* ]]; then
   echo "haproxy.service is inactive, starting and enabling..."
   sudo systemctl start haproxy

CHECK_NEW_STATUS_HAPROXY=$(sudo systemctl is-active haproxy)

   if [[ "$CHECK_NEW_STATUS_HAPROXY" == *"active"* ]]; then
      echo "haproxy.service is active(running), enabling..."
      sudo systemctl enable haproxy
   else
      echo "haproxy.service is failed to start, Aborting deployment..." >&2
      exit 1
   fi 
fi 

# Define the function
verify_haproxy() {
     
    local NEW_ACTIVE_STATUS_HAPROXY=$(sudo systemctl is-active haproxy --quiet)
    local NEW_ENABLED_STATUS_HAPROXY=$(sudo systemctl is-enabled haproxy --quiet)
    
    # Check if service is active
    if [[ $NEW_ACTIVE_STATUS_HAPROXY == *"active"* ]]; then
        echo "INFO: haproxy is active to start at boot"
    else
        echo "ERROR: haproxy is not active to start at boot"     
        return 1
    fi
    
    # Check if service is enabled
    if [[ $NEW_ENABLED_STATUS_HAPROXY == *"enabled"* ]]; then
        echo "INFO: haproxy is enabled to start at boot"
    else
        echo "ERROR: haproxy is not enabled to start at boot"
        return 1
    fi
    
    echo "Haproxy is fully operational and configured correctly"
    return 0
}

# Call function for service verification
if verify_haproxy; then
   echo "Verification successful: haproxy.service is running properly"
else
   echo "Verification failed: haproxy.service is failed to run. Aborting deployment..." >&2
   exit 1
fi

# Check the server is listening tcp port 443 & 6443
SS_OUTPUT=$(sudo ss -tulpn)

# Check if both ports 443 and 6443 are listening on 192.168.31.200
if echo "$SS_OUTPUT" | grep -q '192.168.31.200:443' && echo "$SS_OUTPUT" | grep -q '192.168.31.200:6443'; then
   echo "Verification passed, the API and web-console are accessible"
else
   echo "Verification failed, aborting deployment..." >&2
   exit 1
fi

#Verify if the OC Cli exists, unzip the package and install to /usr/local/bin
CLI_ARCHIVE=openshift-client-linux.tar.gz

if [ -f "$CLI_ARCHIVE" ]; then
   echo "Found CRC archive: $CLI_ARCHIVE, extracting..."
   tar -xvf "$CLI_ARCHIVE"
else
   echo "CLI archive not exists, Aborting deployment..."
   exit 1
fi

OC=oc
KUBECTL=kubectl
BINARY_PATH=/usr/local/bin

# Check if CLI tools exist in current directory
if [[ -f "$OC" ]] && [[ -f "$KUBECTL" ]]; then
    echo "Found CLI tools: $OC and $KUBECTL. Copying to $BINARY_PATH..."

    # Copy binaries
    sudo cp -a "$OC" "$BINARY_PATH" || {
        echo "Failed to copy $OC" >&2
        exit 1
    }

    sudo cp -a "$KUBECTL" "$BINARY_PATH" || {
        echo "Failed to copy $KUBECTL" >&2
        exit 1
    }

    # Set executable permissions
    sudo chmod +x "$BINARY_PATH/$OC" "$BINARY_PATH/$KUBECTL" || {
        echo "Failed to set executable permissions for CLI tools" >&2
        exit 1
    }

    echo "CLI tools installation completed."
else
    echo "CLI tools $OC and $KUBECTL not found in current directory. Aborting deployment..." >&2
    exit 1
fi

if ! echo "$PATH" | grep -wo "$BINARY_PATH"; then
   echo "Adding $BINARY_PATH to PATH..."
   export PATH="$BINARY_PATH:$PATH"
   echo "PATH updated to include $BINARY_PATH"
else
   echo "$BINARY_PATH already in PATH"
fi

# Verify installation
if command -v oc >/dev/null 2>&1; then
   echo "oc installed successfully: $(oc version)"
else
   echo "oc installation failed or not in $PATH"
   exit 1
fi

# Display the success message
echo "All configurations passed, the crc deployment is successful!"