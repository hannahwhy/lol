require 'celluloid'
require 'irb'
require 'json'
require 'launchpad/device'
require 'launchpad/interaction'
require 'mechanize'
require 'pp'
require 'yaml'

$config = YAML.load(File.read(File.expand_path('../config.yml', __FILE__))).freeze

mu = lambda do |path|
  "#{$config['mmonit']['base_url']}/#{path}"
end

$mmonit_urls = {
  'login' => mu['/'],
  'hosts' => mu['/json/status/list']
}.freeze

module LaunchpadRepresentation
  def led_state
    case led
    when '0'; then { :green => :off, :red => :high }
    when '1'; then { :green => :high, :red => :high }
    when '2'; then { :green => :high, :red => :off }
    when '3'; then { :green => :low, :red => :low }
    end
  end
end

# M/Monit's "JSON API" is more like screen-scraping with the incidental JSON
# output.
class Poller
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

    attr_reader :id
    attr_reader :led
    attr_reader :host
    attr_reader :events
    attr_reader :cpu
    attr_reader :mem
    attr_reader :status

    def initialize(data)
      %w(id led host events cpu mem status).each do |attr|
        var = :"@#{attr}"
        instance_variable_set(var, data[attr])
      end
    end
  end
end

$p = Poller.supervise_as :poller

# Launchpad doesn't like Celluloid, it seems
int = Launchpad::Interaction.new

@state = :viewing

int.response_to(:session, :down) do |int, action|
  if @state == :viewing
    puts "Select hosts to SSH to"
    @state = :selecting
  else
    @state = :viewing
  end
end

int.start(:detached => true)

def poller
  Celluloid::Actor[:poller]
end

Thread.new do
  loop do
    poller.records.each.with_index do |r, i|
      x = i % 8
      y = (i / 8) % 8

      int.device.change :grid, { :x => x, :y => y }.merge(r.led_state)
    end

    sleep 15
  end
end

IRB.start
