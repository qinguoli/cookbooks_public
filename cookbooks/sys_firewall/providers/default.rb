# Copyright (c) 2011 RightScale, Inc.
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# 'Software'), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#


action :update do
  
  # Set local variables from attributes
  port = new_resource.port ? new_resource.port : new_resource.name
  protocol = new_resource.protocol
  to_enable = new_resource.enable
  ip_addr = new_resource.ip_addr
  tag = new_resource.machine_tag
  collection_name = new_resource.collection
  
  # We only support ip_addr or tags, however, ip_addr defaults to 'any' so reconcile here
  ip_addr.downcase!
  ip_addr = nil if (ip_addr == "any") && tag  # tags win, so clear 'any'
  raise "ERROR: ip_addr param cannot be used with machine_tag param." if tag && ip_addr

  # Tell user what is going on
  msg = "#{to_enable ? "Enabling" : "Disabling"} firewall rule for port #{port}"
  msg << " only for address #{ip_addr}" if ip_addr
  msg << " on servers with tag #{tag}" if tag
  msg << " using protocol #{protocol}." if protocol
  log msg

  # Update rules 
  unless node[:sys_firewall][:enabled] == "enabled" 
    log "Firewall not enabled. Not adding rule for #{port}."
  else
    
    ip_list = [ ]
    
    # Add specific ip address 
    ip_list << ip_addr if ip_addr

    # Add tagged servers
    if tag
      r = server_collection collection_name do
        tags tag
        action :nothing
      end
      r.run_action(:load)

      # Grab private_ip of all tagged servers
      valid_ip_regex = '(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
      @node[:server_collection][collection_name].each do |_, tags|
        tags.detect { |t| t =~ /^server:private_ip_0=(#{valid_ip_regex})$/ }
        client_ip = Regexp.last_match[1]
        ip_list << client_ip
      end
    end

    # Setup iptables rebuild resouce 
    execute "rebuild-iptables" do
      command "/usr/sbin/rebuild-iptables"
      action :nothing
    end
    
    # Use iptables cookbook to create open/close port for ip list
    ip_list.each do |ip|
      
      log "Adding iptables rule for IP Address: #{ip}"
      
      rule = "port_#{port}"
      rule << "_#{ip.gsub('/','_')}_#{protocol}" 
      iptables_rule rule do
        source "iptables_port.erb"
        cookbook "sys_firewall"
        variables ({ 
          :port => port,
          :protocol => protocol,
          :ip_addr => (ip == "any") ? nil : ip })
        enable to_enable
      end 
    end
  end

end

action :update_request do
  
  # Deal with attributes
  port = new_resource.port ? new_resource.port : new_resource.name
  to_enable = new_resource.enable
  ip_addr = new_resource.ip_addr
  raise "ERROR: client_ip must be specified." unless ip_addr
  tag = new_resource.machine_tag
  raise "ERROR: machine_tag must be specified." unless tag

  # Tell user what is going on
  msg = "Requesting port #{port} be #{to_enable ? "opened" : "closed"}"
  msg << " only for #{ip_addr}." if ip_addr
  msg << " on servers with tag: #{tag}."
  log msg
  
  # Setup attributes
  attrs = {:sys_firewall => {:rule => Hash.new}}
  attrs[:sys_firewall][:rule][:port] = port
  attrs[:sys_firewall][:rule][:enable] = to_enable.to_s # recipe expects a string
  attrs[:sys_firewall][:rule][:ip_address] = ip_addr
  
  # Use RightNet to update firewall rules on all tagged servers
  remote_recipe "Request firewall update" do
    recipe "sys_firewall::setup_rule"
    recipients_tags tag
    attributes attrs
  end 
  
end
