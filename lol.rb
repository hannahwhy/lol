require 'celluloid'
require 'irb'
require 'json'
require 'launchpad/device'
require 'launchpad/interaction'
require 'mechanize'
require 'nokogiri'
require 'pp'
require 'yaml'

$config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__))).freeze

mu = lambda do |path|
  "#{$config['mmonit']['base_url']}/#{path}"
end

ju = lambda do |path|
  "#{$config['jenkins']['base_url']}/#{path}"
end

$mmonit_urls = {
  'login' => mu['/'],
  'hosts' => mu['/json/status/list']
}.freeze

$jenkins_urls = {
  'cc' => ju['/cc.xml']
}.freeze

module LaunchpadRepresentation
  def led_state
    case led
    when '0'; then { :green => :off, :red => :high }
    when '1'; then { :green => :high, :red => :high }
    when '2'; then { :green => :high, :red => :off }
    when '3'; then { :green => :low, :red => :low }
    when :off; then { :green => :off, :red => :off }
    end
  end
end

# M/Monit's "JSON API" is more like screen-scraping with the incidental JSON
# output.
class MMonitPoller
  include Celluloid

  attr_reader :records

  def initialize
    @records = []

    async.start
  end

  def start
    agent = do_login

    # OK, now we can get the host list.  The host list isn't paginated, so a
    # single request is all we need.
    #
    # We update the list every 30 seconds.
    loop do
      page = agent.post $mmonit_urls['hosts']
      process(page.body)
      sleep 15
    end
  end

  def process(data)
    doc = JSON.parse(data)

    records.clear

    doc['records'].each do |record|
      records << Record.new(record)
    end

    records.sort_by!(&:host)
  end

  def do_login
    agent = Mechanize.new
    page = agent.get($mmonit_urls['login'])
    login = page.form_with :action => 'z_security_check'
    login.field_with(:name => 'z_username').value = $config['mmonit']['username']
    login.field_with(:name => 'z_password').value = $config['mmonit']['password']
    page = agent.submit login
    agent
  end

  class Record
    include LaunchpadRepresentation

    ATTRIBUTES = %w(
      id led host events cpu mem status
    ).map(&:to_sym)

    ATTRIBUTES.each { |a| attr_reader a }

    def initialize(data)
      ATTRIBUTES.each do |attr|
        var = :"@#{attr}"
        instance_variable_set(var, data[attr.to_s])
      end
    end

    def name
      host
    end
  end
end

class JenkinsPoller
  include Celluloid

  attr_reader :records
  attr_reader :agent

  def initialize
    @records = []
    @agent = Mechanize.new

    async.start
  end

  def start
    loop do
      process($jenkins_urls['cc'])
      sleep 10
    end
  end

  def process(url)
    page = agent.get(url)
    xml = page.body
    doc = Nokogiri.XML(xml)

    records.clear

    (doc/'Project').each do |prj|
      records << record_from_project(prj)
    end

    records.sort_by!(&:name)
  end

  def attr(prj, key)
    prj.attributes[key].value
  end

  def record_from_project(prj)
    Record.new(
      :web_url => attr(prj, 'webUrl'),
      :name => attr(prj, 'name'),
      :last_build_label => attr(prj, 'lastBuildLabel'),
      :last_build_time => attr(prj, 'lastBuildTime'),
      :last_build_status => attr(prj, 'lastBuildStatus'),
      :activity => attr(prj, 'activity')
    )
  end

  class Record
    include LaunchpadRepresentation

    ATTRIBUTES = %w(
      web_url name last_build_label last_build_time last_build_status activity
    ).map(&:to_sym)

    ATTRIBUTES.each { |a| attr_reader a }

    def initialize(data)
      ATTRIBUTES.each do |attr|
        var = :"@#{attr}"
        instance_variable_set(var, data[attr])
      end
    end

    def led
      if activity == 'Building'
        '1'
      else
        case last_build_status
        when 'Success' then '2'
        when 'Failure' then '0'
        when 'Unstable' then '0'
        when 'Unknown' then :off
        else '3'
        end
      end
    end
  end
end

$mp = MMonitPoller.supervise_as :mmonit_poller
$jp = JenkinsPoller.supervise_as :jenkins_poller

# Launchpad doesn't like Celluloid, it seems
int = Launchpad::Interaction.new

@state = :viewing

int.response_to(:grid, :down) do |interaction, action|
  if @active_poller
    record_index = action[:y] * 8 + action[:x]
    record = send(@active_poller).records[record_index]
    
    puts record.name if record
  end
end

int.response_to(:scene1, :down) do |interaction, action|
  puts "Starting mmonit poller"
  @active_poller = :mmonit_poller
  interaction.device.reset
  refresh(interaction)
end

int.response_to(:scene2, :down) do |interaction, action|
  puts "Starting Jenkins poller"
  @active_poller = :jenkins_poller
  interaction.device.reset
  refresh(interaction)
end

int.response_to(:scene3, :down) do |interaction, action|
  puts "Blanking control"
  @active_poller = nil
  interaction.device.reset
end

int.start(:detached => true)

def mmonit_poller
  Celluloid::Actor[:mmonit_poller]
end

def jenkins_poller
  Celluloid::Actor[:jenkins_poller]
end

@active_poller = nil

def refresh(int)
  return unless @active_poller

  send(@active_poller).records.each.with_index do |r, i|
    x = i % 8
    y = (i / 8) % 8

    if r.led_state
      int.device.change :grid, { :x => x, :y => y }.merge(r.led_state)
    end
  end
end

Thread.abort_on_exception = true

Thread.new do
  loop do
    refresh(int)

    sleep 15
  end
end

$int = int

IRB.start
