#!/usr/bin/env ruby

PASS = "\e[32m\u2713\e[0m".freeze
FAIL = "\e[31m\u2717\e[0m".freeze

RECENT_WINNERS = 'https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt'
ROUND_TYPES = 'https://xmrvsbeast.com/p2pool/select_lists/round-type-list.txt'
PLAYER_LISTS = 'https://xmrvsbeast.com/p2pool/select_lists'

TIMESTAMP_VALID_WITHIN = 60 * 60 # 1 hour

require 'csv'
require 'json'
require 'open-uri'
require 'optparse'
require_relative './roller'

class Parser
  def self.parse(options)
    op = {}
    opt_parser = OptionParser.new do |opts|
      opts.banner = 'Usage: validate.rb [options]'

      opts.on('--height HEIGHT', Integer, 'Specify raffle XMR height') do |h|
        op[:height] = h
      end

      opts.on('--explorer EXPLORER', String, 'XMR Exolorer URL - REQUIRED') do |x|
        op[:explorer] = x
      end

      opts.on('-h', '--help', 'Prints this help') do
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

print 'Validating XMR height exists... '
recent_winners = CSV.parse(URI.open(RECENT_WINNERS).read, col_sep: "\t")

winner = if options[:height]
           recent_winners.select { |w| w[3].to_i == options[:height] }.first
         else
           options[:height] = recent_winners.first[3].to_i
           recent_winners.first
         end

if winner.empty?
  puts "#{FAIL}\nNo winner found matching height #{options[:height]}. Please check that you entered it correctly and have internet access."
  exit 1
end

puts PASS

print 'Validating height matches timestamp... '
reported_ts = Time.parse(winner[1])
xmr_block = JSON.parse(URI.open("#{options[:explorer]}/api/block/#{options[:height]}").read)
xmr_ts = Time.parse(xmr_block['data']['timestamp_utc'])
timediff = (xmr_ts - reported_ts).abs.to_i

if timediff <= TIMESTAMP_VALID_WITHIN
  puts PASS
else
  puts FAIL
  puts "Reported timestamp is #{timediff} seconds away from XMR height, larger than the maximum of #{TIMESTAMP_VALID_WITHIN}."
  exit 1
end

print 'Validating height matches block hash... '
reported_hash = winner[5]
xmr_hash = xmr_block['data']['hash'][0..11]

if reported_hash == xmr_hash
  puts PASS
else
  puts FAIL
  puts "Reported XMR blockhash (#{reported_hash}) is different from actual blockhash at height #{options[:height]} (#{xmr_hash})."
  exit 1
end

print 'Validating round_type... '
rolls = winner[6].split('/').last
reported_round = winner[8]
round_types = File.open('round-type-list.txt', 'w') { |f| f.puts(URI.open(ROUND_TYPES).read) }
expected_round = Roller.roll(xmr_hash, 'round-type-list.txt', rolls)
File.delete('round-type-list.txt')

if reported_round == expected_round
  puts PASS
else
  puts FAIL
  puts "Reported round_type (#{reported_round}) is different from expected round (#{expected_round})."
  exit 1
end

print 'Validating winner... '
rolls = winner[6].split('/').first
reported_winner = winner[0][0..7]
player_list = File.open('players.txt', 'w') { |f| f.puts(URI.open("#{PLAYER_LISTS}/#{xmr_hash}-players.txt").read) }
expected_winner = Roller.roll(xmr_hash, 'players.txt', rolls)
File.delete('players.txt')

if reported_winner == expected_winner
  puts PASS
else
  puts FAIL
  puts "Reported winner (#{reported_winner}) is different from expected winner (#{expected_winner})."
  exit 1
end
