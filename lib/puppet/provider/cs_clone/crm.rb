require 'pathname'
require Pathname.new(__FILE__).dirname.dirname.expand_path + 'corosync'

Puppet::Type.type(:cs_clone).provide(:crm, :parent => Puppet::Provider::Corosync) do
  desc 'Specific provider for a rather specific type since I currently have no plan to
        abstract corosync/pacemaker vs. keepalived. This provider will check the state
        of current primitive start orders on the system; add, delete, or adjust various
        aspects.'

  # Path to the crm binary for interacting with the cluster configuration.
  commands :crm => 'crm'


  # given an XML element containing some <nvpair>s, return a hash. Return an
  # empty hash if `e` is nil.
  def self.nvpairs_to_hash(e)
    return {} if e.nil?

    hash = {}
    e.each_element do |i|
      hash[(i.attributes['name'])] = i.attributes['value']
    end

    hash
  end


  def self.instances

    block_until_ready

    instances = []

    cmd = [ command(:crm), 'configure', 'show', 'xml' ]
    raw, status = Puppet::Util::SUIDManager.run_and_capture(cmd)
    doc = REXML::Document.new(raw)

    REXML::XPath.each(doc, '//clone') do |e|

      items = e.attributes

      primitives = e.elements['primitive']
      rsc = primitives.attributes['id']

      metas = e.elements['meta_attributes']

      order_instance = {
        :name       => items['id'],
        :ensure     => :present,
        :rsc        => rsc,
        :meta       => nvpairs_to_hash(metas),
        :provider   => self.name
      }
      instances << new(order_instance)
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
      :meta       => @resource[:meta],
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


  def meta
    @property_hash[:meta]
  end



  # Our setters for the first and second primitives and score.  Setters are
  # used when the resource already exists so we just update the current value
  # in the property hash and doing this marks it to be flushed.
  def rsc=(should)
    @property_hash[:rsc] = should
  end

  def meta=(should)
    @property_hash[:meta] = should
  end


  # Flush is triggered on anything that has been detected as being
  # modified in the property_hash.  It generates a temporary file with
  # the updates that need to be made.  The temporary file is then used
  # as stdin for the crm command.
  def flush
    unless @property_hash.empty?

      unless @property_hash[:meta].empty?
        metas = 'meta '
        @property_hash[:meta].each_pair do |k,v|
          metas << "#{k}=#{v} "
        end
      end

      updated = 'clone '
      updated << "#{@property_hash[:name]} #{@property_hash[:rsc]} "
      updated << "#{metas} " unless metas.nil?
      Tempfile.open('puppet_crm_update') do |tmpfile|
        tmpfile.write(updated)
        tmpfile.flush
        ENV['CIB_shadow'] = @resource[:cib]
        crm('configure', 'load', 'update', tmpfile.path.to_s)
      end
    end
  end
end
