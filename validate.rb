#!/usr/bin/env ruby

PASS = "\e[32m\u2713\e[0m".freeze
FAIL = "\e[31m\u2717\e[0m".freeze

RECENT_WINNERS = 'https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt'.freeze
ROUND_TYPES = 'https://xmrvsbeast.com/p2pool/select_lists/round-type-list.txt'.freeze
PLAYER_LISTS = 'https://xmrvsbeast.com/p2pool/select_lists'.freeze

TIMESTAMP_VALID_WITHIN = (60 * 60).freeze # 1 hour

ERR_NO_RECENT_WINNERS = 1.freeze
ERR_NO_WINNER_AT_HEIGHT = 2.freeze
ERR_NO_BLOCKHASH = 3.freeze
ERR_BAD_TIMESTAMP = 4.freeze
ERR_BLOCKHASH_NO_MATCH_HEIGHT = 5.freeze
ERR_NO_ROUND_TYPES = 6.freeze
ERR_BAD_ROUND_TYPE = 7.freeze
ERR_NO_PLAYERS_LIST = 8.freeze
ERR_BAD_WINNER = 9.freeze

require 'csv'
require 'json'
require 'open-uri'
require 'optparse'
require_relative './roller'

class Parser
  def self.parse(options)
    op = {}
    opt_parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ./validate.rb [options]'

      opts.on('-x', '--explorer=EXPLORER', String, 'REQUIRED. XMR Exolorer URL. Must be an instance of the Onion Monero Blockchain explorer, such as https://xmrchain.net/.') do |x|
        op[:explorer] = x
      end

      opts.on('-h', '--height=HEIGHT', Integer, 'Specify raffle XMR height - defaults to the most recent winner\'s reported height') do |h|
        op[:height] = h
      end

      opts.on('-q', '--quiet', 'Do not print output.') do
        op[:quiet] = true
      end

      opts.on('-c', '--cache-responses[=MINUTES]', Integer, 'Cache web responses using VCR gem (must be installed) for [MINUTES] minutes (default 30).') do |m|
        require 'vcr'

        VCR.configure do |c|
          c.hook_into :webmock
          c.cassette_library_dir = '/tmp/vcr'
        end

        op[:cache] = m || 30
      end

      opts.on('-?', '--help', 'Prints this help') do
        puts opts
        exit 0
      end
    end

    opt_parser.parse!(options)
    return op
  end
end

options = Parser.parse(ARGV)

if !options.has_key?(:explorer)
  puts '--explorer is required!'
  Parser.parse(%w[--help])
  exit 1
end

print 'Validating XMR height exists in winners list... ' unless options[:quiet]

begin
  recent_winners = if options[:cache]
                     VCR.use_cassette('recent_winners', record: :new_episodes, re_record_interval: options[:cache] * 60, match_requests_on: [:method, :host, :path]) do
                       CSV.parse(URI.open(RECENT_WINNERS).read, col_sep: "\t")
                     end
                   else
                     CSV.parse(URI.open(RECENT_WINNERS).read, col_sep: "\t")
                   end
rescue => e
  puts e.backtrace.join
  puts FAIL unless options[:quiet]
  puts "Unable to download #{RECENT_WINNERS}, please check your internet connection." unless options[:quiet]
  exit ERR_NO_RECENT_WINNERS
end

winner = if options[:height]
           recent_winners.select { |w| w[3].to_i == options[:height] }.first
         else
           options[:height] = recent_winners.first[3].to_i
           recent_winners.first
         end

if !winner
  puts FAIL unless options[:quiet]
  puts "No winner found matching height #{options[:height]}. Please check that you entered it correctly and have internet access." unless options[:quiet]
  exit ERR_NO_WINNER_AT_HEIGHT
end

puts PASS unless options[:quiet]

print 'Validating height matches timestamp... ' unless options[:quiet]
reported_ts = Time.parse(winner[1])

begin
  xmr_block = if options[:cache]
                VCR.use_cassette('recent_winners', record: :new_episodes, re_record_interval: options[:cache] * 60, match_requests_on: [:method, :host, :path]) do
                  JSON.parse(URI.open("#{options[:explorer]}/api/block/#{options[:height]}").read)
                end
              else
                JSON.parse(URI.open("#{options[:explorer]}/api/block/#{options[:height]}").read)
              end
rescue
  puts FAIL unless options[:quiet]
  puts "Unable to fetch blockchain hash from #{options[:explorer]}/api/block/#{options[:height]}, please check your internet connection." unless options[:quiet]
  exit ERR_NO_BLOCKHASH
end

xmr_ts = Time.parse(xmr_block['data']['timestamp_utc'])
timediff = (xmr_ts - reported_ts).abs.to_i

if timediff <= TIMESTAMP_VALID_WITHIN
  puts PASS unless options[:quiet]
else
  puts FAIL unless options[:quiet]
  puts "Reported timestamp is #{timediff} seconds away from XMR height, larger than the maximum of #{TIMESTAMP_VALID_WITHIN}." unless options[:quiet]
  exit ERR_BAD_TIMESTAMP
end

print 'Validating height matches block hash... ' unless options[:quiet]
reported_hash = winner[5]
xmr_hash = xmr_block['data']['hash'][0..11]

if reported_hash == xmr_hash
  puts PASS unless options[:quiet]
else
  puts FAIL unless options[:quiet]
  puts "Reported XMR blockhash (#{reported_hash}) is different from actual blockhash at height #{options[:height]} (#{xmr_hash})." unless options[:quiet]
  exit ERR_BLOCKHASH_NO_MATCH_HEIGHT
end

print 'Validating round_type... ' unless options[:quiet]
rolls = winner[6].split('/').last
reported_round = winner[8]

begin
  round_types = if options[:cache]
                  VCR.use_cassette('recent_winners', record: :new_episodes, re_record_interval: options[:cache] * 60, match_requests_on: [:method, :host, :path]) do
                    URI.open(ROUND_TYPES).read.split("\n")
                  end
                else
                  URI.open(ROUND_TYPES).read.split("\n")
                end
rescue
  puts FAIL unless options[:quiet]
  puts "Unable to fetch round_types data from #{ROUND_TYPES}, please check your internet connection." unless options[:quiet]
  exit ERR_NO_ROUND_TYPES
end

expected_round = Roller.roll(xmr_hash, round_types, rolls)

if reported_round == expected_round
  puts PASS unless options[:quiet]
else
  puts FAIL unless options[:quiet]
  puts "Reported round_type (#{reported_round}) is different from expected round (#{expected_round})." unless options[:quiet]
  exit ERR_BAD_ROUND_TYPE
end

print 'Validating winner... ' unless options[:quiet]
rolls = winner[6].split('/').first
reported_winner = winner[0][0..7]

begin
  player_list = if options[:cache]
                  VCR.use_cassette('recent_winners', record: :new_episodes, re_record_interval: options[:cache] * 60, match_requests_on: [:method, :host, :path]) do
                    URI.open("#{PLAYER_LISTS}/#{xmr_hash}-players.txt").read.split("\n")
                  end
                else
                  URI.open("#{PLAYER_LISTS}/#{xmr_hash}-players.txt").read.split("\n")
                end
rescue
  puts FAIL unless options[:quiet]
  puts "Unable to fetch players data from #{PLAYER_LISTS}/#{xmr_hash}-players.txt, please check your internet connection." unless options[:quiet]
  exit ERR_NO_PLAYERS_LIST
end

expected_winner = Roller.roll(xmr_hash, player_list, rolls)

if reported_winner == expected_winner
  puts PASS unless options[:quiet]
else
  puts FAIL unless options[:quiet]
  puts "Reported winner (#{reported_winner}) is different from expected winner (#{expected_winner})." unless options[:quiet]
  exit ERR_BAD_WINNER
end
