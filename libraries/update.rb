module AutoUpdater
  # noinspection ALL
  class Update < Chef::Resource
    resource_name :auto_updater_update

    property :update_message, String, name_property: true
    # How often (in hours) to check for updates, and if necessary update and reboot?
    property :check_interval_hours, Numeric, default: 24 * 30
    property :node_check_delay_hours, Numeric, default: 24 * 4 # +/- 4 days gives about 8 days total.
    property :reboot_if_needed, [true, false], default: false
    property :force_update_now, [true, false], default: false
    property :node_name, String

    action :run do
      r = new_resource

      require 'digest'
      require 'colored2'

      node_display_name  = r.node_name || node['name']
      offset             = (Digest::MD5.hexdigest(node_display_name).gsub(/[a-f]/i, '').to_i % r.node_check_delay_hours) - r.node_check_delay_hours
      period_hours       = r.check_interval_hours + offset
      period_seconds     = period_hours * 60 * 60
      last_update        = node['auto-updater']['update']['last_update_at'] || 0
      second_till_update = (Time.now.to_i - last_update) - period_seconds
      host_name          = node_display_name.bold.green

      if r.force_update_now || last_update.nil? || second_till_update > 0
        env = { 'DEBIAN_FRONTEND' => 'noninteractive' }
        Chef::Log.warn("\n\n========> WARNING! Auto-Update of host #{host_name} starting, reboot may be required...")
        Chef::Log.warn("\n\n========>          Last updated at #{last_update ? Time.at(last_update).to_s : '(never)'}")

        reboot('reboot instance') { action :nothing } if r.reboot_if_needed

        apt_args = '-o DPkg::options::="--force-confdef" -o DPkg::options::="--force-confold"'

        execute 'apt-auto-update' do
          command 'apt-get -y update'
          live_stream true
          environment env
          user 'root'
          cwd '/'
        end

        execute 'dpkg --configure -a' do
          user 'root'
          cwd '/'
          ignore_failure true
        end

        execute 'apt-auto-update' do
          command "apt-get -y #{apt_args} update"
          live_stream true
          environment env
          user 'root'
          cwd '/'
        end

        execute 'apt-dist-upgrade' do
          command "apt-get -y #{apt_args} dist-upgrade"
          live_stream true
          environment env
          user 'root'
          cwd '/'
        end

        execute 'apt-autoremove' do
          command 'apt autoremove -y'
          environment env
          ignore_failure true
          action :run
        end

        # Save when we last updated.
        node.normal['auto-updater']['update']['last_update_at'] = Time.now.to_i

        if r.reboot_if_needed
          execute 'check if a reboot is required' do
            command 'echo reboot is scheduled'
            only_if 'sudo /usr/sbin/update-motd | grep restart'
            notifies(:request_reboot, 'reboot[reboot instance]', :delayed)
          end
        end
      else
        days_till_update = -1.0 * second_till_update.to_f / (60 * 60 * 24).to_f
        color            = if days_till_update < 2
                             :red
                           elsif days_till_update < 7
                             :yellow
                           else
                             :green
                           end
        update_message   = "#{sprintf '%.2f', days_till_update} days"
        update_message   = update_message.send(color) if update_message.respond_to?(color)
        Chef::Log.warn("\n\n⎯⎯⎯⎯⎯⎯⎯⎯⎯  NOTE: #{node_display_name} will auto-update in #{update_message} ⎯⎯⎯⎯⎯⎯⎯⎯⎯ \n\n")
      end
    end
  end
end
