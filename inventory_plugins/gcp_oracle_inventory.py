
from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

DOCUMENTATION = r'''
    name: gcp_oracle_inventory
    plugin_type: inventory
    short_description: Returns Ansible inventory from a YAML configuration file
    description: Returns Ansible inventory from a YAML configuration file
    options:
      plugin:
          description: Name of the plugin
          required: true
          choices: ['gcp_oracle_inventory']
      config_file:
        description: Path to the YAML configuration file
        required: true
'''

from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.errors import AnsibleError, AnsibleParserError
import yaml

class InventoryModule(BaseInventoryPlugin):
    NAME = 'gcp_oracle_inventory'

    def verify_file(self, path):
        '''Return true/false if this is possibly a valid file for this plugin to consume'''
        valid = False
        if super(InventoryModule, self).verify_file(path):
            if path.endswith(('gcp_oracle.yml', 'gcp_oracle.yaml')):
                valid = True
        return valid

    def parse(self, inventory, loader, path, cache=True):
        '''Return dynamic inventory from parsing the YAML file'''
        super(InventoryModule, self).parse(inventory, loader, path, cache)
        self._read_config_data(path)
        self._populate_inventory()

    def _read_config_data(self, path):
        '''Read the YAML configuration file'''
        try:
            with open(path, 'r') as f:
                self.config_data = yaml.safe_load(f)
        except Exception as e:
            raise AnsibleParserError('Error reading YAML configuration file: %s' % e)

    def _populate_inventory(self):
        '''Populate the inventory based on the configuration'''
        if self.config_data.get('cluster_type') == 'RAC':
            self._populate_rac_inventory()
        elif self.config_data.get('cluster_type') == 'DG':
            self._populate_dg_inventory()
        else:
            self._populate_si_inventory()

    def _populate_si_inventory(self):
        '''Populate a single instance inventory'''
        hostgroup_name = self.config_data.get('instance_hostgroup_name', 'dbasm')
        self.inventory.add_group(hostgroup_name)
        hostname = self.config_data.get('instance_hostname')
        ssh_host = self.config_data.get('instance_ip_addr')
        self.inventory.add_host(hostname, group=hostgroup_name)
        self.inventory.set_variable(hostname, 'ansible_ssh_host', ssh_host)
        self._set_common_variables(hostname)

    def _populate_dg_inventory(self):
        '''Populate a Data Guard inventory'''
        hostgroup_name = self.config_data.get('instance_hostgroup_name', 'dbasm')
        self.inventory.add_group(hostgroup_name)
        hostname = self.config_data.get('instance_hostname')
        ssh_host = self.config_data.get('instance_ip_addr')
        self.inventory.add_host(hostname, group=hostgroup_name)
        self.inventory.set_variable(hostname, 'ansible_ssh_host', ssh_host)
        self._set_common_variables(hostname)

        self.inventory.add_group('primary')
        primary_ssh_host = self.config_data.get('primary_ip_addr')
        self.inventory.add_host('primary1', group='primary')
        self.inventory.set_variable('primary1', 'ansible_ssh_host', primary_ssh_host)
        self._set_common_variables('primary1')


    def _populate_rac_inventory(self):
        '''Populate a RAC inventory'''
        hostgroup_name = self.config_data.get('instance_hostgroup_name', 'dbasm')
        self.inventory.add_group(hostgroup_name)
        cluster_config = self.config_data.get('cluster_config', [])
        for cluster in cluster_config:
            for node in cluster.get('nodes', []):
                hostname = node.get('node_name')
                ssh_host = node.get('host_ip')
                self.inventory.add_host(hostname, group=hostgroup_name)
                self.inventory.set_variable(hostname, 'ansible_ssh_host', ssh_host)
                self.inventory.set_variable(hostname, 'vip_name', node.get('vip_name'))
                self.inventory.set_variable(hostname, 'vip_ip', node.get('vip_ip'))
                self._set_common_variables(hostname)

            for key, value in cluster.items():
                if key != 'nodes':
                    self.inventory.set_variable(hostgroup_name, key, value)

    def _set_common_variables(self, hostname):
        '''Set common variables for a host'''
        for key, value in self.config_data.items():
            self.inventory.set_variable(hostname, key, value)
