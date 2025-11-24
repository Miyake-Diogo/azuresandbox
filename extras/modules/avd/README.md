# Azure Virtual Desktop Module (avd)

## Contents

* [Overview](#overview)
* [Documentation](#documentation)

## Overview

This module deploys Azure Virtual Desktop (AVD) with both personal desktop and RemoteApp configurations. It creates two separate host pools with dedicated session hosts, workspaces, and application groups. The personal desktop host pool provides full Windows desktop access, while the RemoteApp host pool streams individual applications like Microsoft Edge.

## Documentation

Additional information about this module.

* [Dependencies](#dependencies)
* [Module Structure](#module-structure)
* [Usage](#usage)
* [Input Variables](#input-variables)
* [Module Resources](#module-resources)
* [Output Variables](#output-variables)
* [Configuration Details](#configuration-details)
* [Limitations](#limitations)

### Dependencies

This module depends upon resources provisioned in the following modules:

* Root (resource group)
* vnet-shared or vnet-app (virtual networks / subnets)

Additional requirements:

* Azure AD user/group object IDs for role assignments

### Module Structure

```plaintext
├── compute.tf      # Virtual machines and extensions for both host pools
├── locals.tf       # Local values (role IDs, RDP properties)
├── main.tf         # AVD control plane resources (workspaces, host pools, app groups)
├── network.tf      # Network interfaces for session hosts
├── outputs.tf      # Module outputs
├── terraform.tf    # Terraform configuration block
└── variables.tf    # Input variables
```

### Usage

```hcl
module "avd" {
  source = "./extras/modules/avd"

  # Resource Group
  resource_group_id   = azurerm_resource_group.this.id
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  
  # Networking (from existing infrastructure)
  subnet_id = module.vnet_app.subnet_ids["snet-app-01"]
  
  # Virtual Machines
  vm_name_personal   = "avdpersonal"
  vm_name_remoteapp  = "avdremoteapp"
  vm_size            = "Standard_D4ds_v4"
  admin_username     = "azureuser"
  admin_password     = "P@ssw0rd1234!"
  vm_image_sku       = "win11-24h2-avd-m365"
  
  # AVD Configuration
  configuration_zip_url         = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02790.438.zip"
  security_principal_object_ids = ["00000000-0000-0000-0000-000000000000"]
  
  # Naming
  unique_seed = "12345"
  
  # Tags
  tags = {
    project     = "avd"
    environment = "dev"
  }
}
```

### Input Variables

Variable | Default | Description
--- | --- | ---
admin_password | | Administrator password for session host VMs (sensitive).
admin_username | | Administrator username for session host VMs.
configuration_zip_url | Microsoft Gallery URL | URL to DSC configuration ZIP file for AVD agent installation.
location | | Azure region where resources will be created.
resource_group_id | | Resource ID of the existing resource group.
resource_group_name | | Name of the existing resource group.
security_principal_object_ids | | Azure AD object IDs for role assignments.
subnet_id | | Resource ID of existing subnet for session hosts.
tags | | Map of resource tags.
unique_seed | | Seed value for Azure naming module.
vm_image_sku | win11-24h2-avd-m365 | Marketplace image SKU for session host VMs.
vm_name_personal | sessionhost1 | Name of the personal desktop session host virtual machine.
vm_name_remoteapp | sessionhost2 | Name of the RemoteApp session host virtual machine.
vm_size | Standard_D4ds_v4 | Azure VM size for session host VMs.

### Module Resources

Address | Name | Notes
--- | --- | ---
azurerm_virtual_desktop_workspace.personal | personal | Personal desktop workspace.
azurerm_virtual_desktop_host_pool.personal | personal | Pooled host pool for desktop (max 2 sessions).
azurerm_virtual_desktop_application_group.personal | personal | Desktop application group.
azurerm_virtual_desktop_workspace_application_group_association.personal | | Links personal workspace to application group.
azurerm_role_assignment.personal | | Desktop Virtualization User role on personal app group.
azurerm_virtual_desktop_host_pool_registration_info.personal | | Registration token for personal host pool.
azurerm_virtual_desktop_workspace.remoteapp | remoteapp | RemoteApp workspace.
azurerm_virtual_desktop_host_pool.remoteapp | remoteapp | Pooled host pool for RemoteApp (max 10 sessions).
azurerm_virtual_desktop_application_group.remoteapp | remoteapp | RemoteApp application group.
azurerm_virtual_desktop_application.edge | MicrosoftEdge | Microsoft Edge published application.
azurerm_virtual_desktop_workspace_application_group_association.remoteapp | | Links RemoteApp workspace to application group.
azurerm_role_assignment.remoteapp | | Desktop Virtualization User role on RemoteApp app group.
azurerm_virtual_desktop_host_pool_registration_info.remoteapp | | Registration token for RemoteApp host pool.
azurerm_windows_virtual_machine.personal | personal | Windows 11 multi-session session host for personal desktop.
azurerm_windows_virtual_machine.remoteapp | remoteapp | Windows 11 multi-session session host for RemoteApp.
azurerm_network_interface.personal | personal | Network interface with accelerated networking for personal VM.
azurerm_network_interface.remoteapp | remoteapp | Network interface with accelerated networking for RemoteApp VM.
azurerm_virtual_machine_extension.guest_attestation_personal | GuestAttestation | Guest attestation for personal VM.
azurerm_virtual_machine_extension.dsc_personal | DSC | Joins personal VM to host pool.
azurerm_virtual_machine_extension.aad_login_personal | AADLoginForWindows | Azure AD login for personal VM.
azurerm_virtual_machine_extension.guest_attestation_remoteapp | GuestAttestation | Guest attestation for RemoteApp VM.
azurerm_virtual_machine_extension.dsc_remoteapp | DSC | Joins RemoteApp VM to host pool.
azurerm_virtual_machine_extension.aad_login_remoteapp | AADLoginForWindows | Azure AD login for RemoteApp VM.
azurerm_role_assignment.vm_users | | VM User Login role on resource group.
time_offset.this | | 2-hour expiration for registration tokens.
module.naming | | Azure naming module instance for consistent resource naming.

### Output Variables

Name | Description
--- | ---
resource_ids | Map of all AVD resource IDs including personal and RemoteApp host pools, application groups, workspaces, and both session host VMs.
resource_names | Map of all AVD resource names including personal and RemoteApp host pools, application groups, workspaces, and both session host VMs.

#### Output Structure

```hcl
resource_ids = {
  avd_application_group_personal         = "..."
  avd_application_group_remoteapp        = "..."
  avd_host_pool_personal                 = "..."
  avd_host_pool_remoteapp                = "..."
  avd_workspace_personal                 = "..."
  avd_workspace_remoteapp                = "..."
  virtual_machine_session_host_personal  = "..."
  virtual_machine_session_host_remoteapp = "..."
}
```

### Configuration Details

#### Personal Desktop Host Pool

* **Type**: Pooled
* **Load Balancing**: BreadthFirst
* **Maximum Sessions**: 2 per host
* **Preferred App Group Type**: Desktop
* **RDP Properties**: Full redirection enabled (drives, clipboard, printers, devices, audio, video, smart cards, USB, webcams, multi-monitor)

#### RemoteApp Host Pool

* **Type**: Pooled
* **Load Balancing**: BreadthFirst
* **Maximum Sessions**: 10 per host
* **Preferred App Group Type**: RailApplications
* **RDP Properties**: Full redirection enabled (drives, clipboard, printers, devices, audio, video, smart cards, USB, webcams, multi-monitor)
* **Published Applications**: Microsoft Edge (additional applications can be added)

#### Session Host VMs

* **Image**: Windows 11 multi-session with Microsoft 365 Apps (configurable via `vm_image_sku`)
* **Security**: Trusted Launch with Secure Boot and vTPM enabled
* **Storage**: Premium SSD managed disk
* **Networking**: Accelerated networking enabled
* **Authentication**: Azure AD joined with AAD login extension
* **License**: Windows Client license type

#### Role Assignments

Role assignments are created for each security principal:

* **Desktop Virtualization User** (on both Application Groups): Allows users to access AVD desktops and RemoteApps
* **Virtual Machine User Login** (on Resource Group): Allows Azure AD authentication to all session hosts

#### Notes

* The module creates two separate host pools: one for personal desktops and one for RemoteApp streaming
* Host pool registration tokens are configured with a 2-hour expiration
* The DSC extension automatically joins each session host to its respective host pool
* All AVD resources are named using the Azure naming module with the provided `unique_seed`
* The `admin_password` must meet Azure password complexity requirements (12-123 characters)
* The `admin_username` is limited to 20 characters and cannot be a reserved name (e.g., admin, administrator)
* Ensure the `security_principal_object_ids` correspond to valid Azure AD users/groups
* Microsoft Edge is published by default in the RemoteApp group; additional applications can be added via `azurerm_virtual_desktop_application` resources
* Both session hosts use the same subnet for simplified networking

#### Requirements

Name | Version
--- | ---
terraform | >= 1.9
azurerm | ~> 4.0
time | ~> 0.12

#### Providers

Name | Version
--- | ---
azurerm | ~> 4.0
time | ~> 0.12

#### Modules

Name | Source | Version
--- | --- | ---
naming | Azure/naming/azurerm | ~> 0.4.2

### Limitations

* This module creates one session host per host pool (two total VMs - suitable for testing/POC scenarios).
* For production deployments, consider scaling to multiple session hosts per pool.
* The module requires existing networking infrastructure (resource group and subnet).
* Both host pools share the same security principal assignments.
* Published applications in RemoteApp are currently hardcoded; consider parameterizing for flexibility.

### Related Documentation

* [Azure Virtual Desktop Documentation](https://docs.microsoft.com/azure/virtual-desktop/)
* [Trusted Launch for Azure VMs](https://docs.microsoft.com/azure/virtual-machines/trusted-launch)
* [Azure AD joined VMs](https://docs.microsoft.com/azure/active-directory/devices/concept-azure-ad-join)
