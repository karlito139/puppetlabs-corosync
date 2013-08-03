require 'pathname'
require Pathname.new(__FILE__).dirname.dirname.expand_path + 'corosync'

Puppet::Type.type(:cs_location).provide(:crm, :parent => Puppet::Provider::Corosync) do
  desc 'Specific provider for a rather specific type since I currently have no plan to
        abstract corosync/pacemaker vs. keepalived. This provider will check the state
        of current primitive start orders on the system; add, delete, or adjust various
        aspects.'

  # Path to the crm binary for interacting with the cluster configuration.
  commands :crm => 'crm'

  def self.instances

    block_until_ready

    instances = []

    cmd = [ command(:crm), 'configure', 'show', 'xml' ]
    raw, status = Puppet::Util::SUIDManager.run_and_capture(cmd)
    doc = REXML::Document.new(raw)

    doc.root.elements['configuration'].elements['constraints'].each_element('rsc_location') do |e|

      items = e.attributes

      rule = e.elements['rule']
      attr_rule = rule.attributes

      str_rule = "$role="
      str_rule << attr_rule['role']
      str_rule << " "
      str_rule << attr_rule['score']
      str_rule << ": "

      size_operator = attr_rule['boolean-op'].length+3


      rule.each_element('expression') do |f|

        attr_expression = f.attributes

        str_rule << ""

        if attr_expression['operation'] == "lte"

          str_rule << attr_expression['attribute']
          str_rule << " "
          str_rule << attr_expression['type']
          str_rule << ":"
          str_rule << attr_expression['operation']
          str_rule << " "
          str_rule << attr_expression['value']
          str_rule << " "
        else

          str_rule << attr_expression['operation']
          str_rule << " "
          str_rule << attr_expression['attribute']
          str_rule << " "
        end

        str_rule << attr_rule['boolean-op']
        str_rule << " "
      end

      str_rule = str_rule[0..-size_operator]


      location_instance = {
        :name       => items['id'],
        :ensure     => :present,
        :rsc        => items['rsc'],
        :rule       => str_rule,
        :provider   => self.name
      }
      instances << new(location_instance)
    end
    instances
  end

  # Create just adds our resource to the property_hash and flush will take care
  # of actually doing the work.
  def create
    @property_hash = {
      :name       => @resource[:name],
      :ensure     => :present,
      :rsc        => @resource[:rsc],
      :rule       => @resource[:rule],
      :cib        => @resource[:cib],
    }
  end

  # Unlike create we actually immediately delete the item.
  def destroy
    debug('Revmoving order directive')
    crm('configure', 'delete', @resource[:name])
    @property_hash.clear
  end

  # Getters that obtains the first and second primitives and score in our
  # ordering definintion that have been populated by prefetch or instances
  # (depends on if your using puppet resource or not).
  def rsc
    @property_hash[:rsc]
  end

  def rule
    @property_hash[:rule]
  end

  # Our setters for the first and second primitives and score.  Setters are
  # used when the resource already exists so we just update the current value
  # in the property hash and doing this marks it to be flushed.
  def rsc=(should)
    @property_hash[:rsc] = should
  end

  def rule=(should)
    @property_hash[:rule] = should
  end

  # Flush is triggered on anything that has been detected as being
  # modified in the property_hash.  It generates a temporary file with
  # the updates that need to be made.  The temporary file is then used
  # as stdin for the crm command.
  def flush
    unless @property_hash.empty?
      updated = 'location '
      updated << "#{@property_hash[:name]} #{@property_hash[:rsc]}"
      updated << "rule #{@property_hash[:rule]} "

      Tempfile.open('puppet_crm_update') do |tmpfile|
        tmpfile.write(updated)
        tmpfile.flush
        ENV['CIB_shadow'] = @resource[:cib]
        crm('configure', 'load', 'update', tmpfile.path.to_s)
      end
    end
  end
end
