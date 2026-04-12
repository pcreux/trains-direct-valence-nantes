#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Lists all direct train connections between Valence TGV and Angers for the next 30 days.
# Usage: NAVITIA_TOKEN=<your_token> ruby direct_connections.rb

require 'net/http'
require 'json'
require 'date'
require 'uri'
require 'dotenv/load'

TOKEN = ENV.fetch('NAVITIA_TOKEN') { abort 'Set NAVITIA_TOKEN in .env or the environment.' }
BASE  = 'https://api.sncf.com/v1/coverage/sncf'

def api_get(path, params = {})
  uri = URI("#{BASE}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?

  retries = 0
  begin
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(TOKEN, '')
      response = http.request(req)
      body     = JSON.parse(response.body)
      # 404 with date_out_of_bounds means we've passed the timetable horizon — signal with nil
      return nil if response.code == '404' && body.dig('error', 'id') == 'date_out_of_bounds'
      # 503 dead_socket is transient — retry
      raise "503" if response.code == '503'
      abort "API error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      body
    end
  rescue => e
    retries += 1
    if retries <= 5
      wait = retries * 2
      warn "  Retrying in #{wait}s (#{e.message})…"
      sleep wait
      retry
    end
    abort "API failed after #{retries} retries: #{e.message}"
  end
end

def resolve_stop(query)
  data  = api_get('/places', q: query, 'type[]' => 'stop_area', count: 5)
  stops = (data['places'] || []).select { |p| p['embedded_type'] == 'stop_area' }
  abort "No stop area found for '#{query}'" if stops.empty?
  stop  = stops.first
  warn "  #{query.ljust(20)} → #{stop['name']} (#{stop['id']})"
  stop['id']
end

# Fetch all direct journeys between two stops over a date range,
# iterating day by day to avoid stopping early when a day has no trains.
def fetch_direct_journeys(from_id, to_id, start_dt, end_dt)
  seen    = {}
  results = []
  date    = start_dt.to_date

  while date <= end_dt.to_date
    # Start each day at 04:00 to catch early-morning trains
    current = DateTime.new(date.year, date.month, date.day, 4, 0, 0)
    day_end = DateTime.new(date.year, date.month, date.day, 23, 59, 0)

    loop do
      break if current > day_end

      data  = api_get('/journeys',
        from:                from_id,
        to:                  to_id,
        datetime:            current.strftime('%Y%m%dT%H%M%S'),
        datetime_represents: 'departure',
        max_nb_transfers:    0,
        min_nb_journeys:     10,
        direct_path:         'none'
      )

      return results if data.nil?  # past timetable horizon

      trips = data['journeys'] || []
      break if trips.empty?

      trips.each do |trip|
        dep_str = trip['departure_date_time']
        dep     = DateTime.strptime(dep_str, '%Y%m%dT%H%M%S')

        # Only keep trains departing today and within the overall window
        next if dep.to_date != date
        next if seen[dep_str]
        next if dep < start_dt || dep > end_dt

        seen[dep_str] = true

        arr    = DateTime.strptime(trip['arrival_date_time'], '%Y%m%dT%H%M%S')
        pt_sec = (trip['sections'] || []).find { |s| s['type'] == 'public_transport' }
        info   = pt_sec&.fetch('display_informations', {}) || {}

        results << {
          dep:      dep,
          arr:      arr,
          duration: trip['duration'] / 60,
          mode:     info['commercial_mode'] || '',
          train:    info['direction']        || info['label'] || info['headsign'] || '',
          network:  info['network']         || ''
        }
      end

      # All returned trips are beyond today → no need to continue this day
      last_dep = DateTime.strptime(trips.last['departure_date_time'], '%Y%m%dT%H%M%S')
      break if last_dep.to_date > date

      current = last_dep + Rational(1, 1440)
    end

    date += 1
  end

  results.sort_by { |r| r[:dep] }
end

def print_table(title, results)
  puts title
  if results.empty?
    puts "  (none)"
    puts
    return
  end
  puts format('  %-18s  %-5s  %-5s  %5s  %-20s  %s', 'Date', 'Dep', 'Arr', 'Min', 'Mode', 'Direction')
  puts '  ' + '-' * 66
  results.each do |r|
    puts format('  %-18s  %-5s  %-5s  %5d  %-20s  %s',
      r[:dep].strftime('%Y-%m-%d %a'),
      r[:dep].strftime('%H:%M'),
      r[:arr].strftime('%H:%M'),
      r[:duration],
      r[:mode],
      r[:train])
  end
  puts "  #{results.size} connection(s)"
  puts
end

warn 'Resolving stop areas…'
valence_id = resolve_stop('Valence TGV')
angers_id  = resolve_stop('Angers Saint-Laud')

start_dt = DateTime.now
end_dt   = DateTime.now + 30

warn "Fetching journeys #{start_dt.strftime('%Y-%m-%d')} → #{end_dt.strftime('%Y-%m-%d')}…"

outbound = fetch_direct_journeys(valence_id, angers_id, start_dt, end_dt)
warn "  Valence → Angers: #{outbound.size} found"

inbound  = fetch_direct_journeys(angers_id, valence_id, start_dt, end_dt)
warn "  Angers → Valence: #{inbound.size} found"

puts
puts "Direct TGV connections — #{start_dt.strftime('%Y-%m-%d')} to #{end_dt.strftime('%Y-%m-%d')}"
puts '=' * 65
puts
print_table('Valence TGV → Angers Saint-Laud', outbound)
print_table('Angers Saint-Laud → Valence TGV', inbound)
