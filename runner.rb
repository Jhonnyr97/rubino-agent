#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'

WIDTH    = (IO.console&.winsize&.[](1) || 80) - 2
LANES    = 3          # numero di corsie
CAR_X    = 6          # colonna fissa della macchina
GAME_ROWS = LANES + 2 # +2 per i bordi stradali

# Scrolling parte dalla riga GAME_ROWS+1
SETUP    = "\e[?25l\e[#{GAME_ROWS + 1};999r"
TEARDOWN = "\e[r\e[?25h"

CAR = ['>', '>', '>']   # simbolo macchina per ogni corsia

@running   = true
@lane      = 1          # corsia attuale 0..LANES-1
@obstacles = []         # [{x:, lane:}]
@frame     = 0
@score     = 0

def spawn_obstacle
  last_x = @obstacles.map { |o| o[:x] }.max || 0
  gap     = rand(10..18)
  # evita di spawnare nella stessa corsia consecutivamente
  used_lane = @obstacles.last&.dig(:lane)
  lane = ([0, 1, 2] - [used_lane]).sample
  @obstacles << { x: [last_x + gap + WIDTH, WIDTH + 5].max, lane: lane }
end

# Colori ANSI per corsia
LANE_BG  = ["\e[48;5;236m", "\e[48;5;238m", "\e[48;5;236m"]
ROAD_TOP = "\e[48;5;240m\e[90m"
ROAD_BOT = "\e[48;5;240m\e[90m"

def render
  lines = Array.new(LANES) { |l| Array.new(WIDTH, ' ') }

  # Strisce tratteggiate divisorie
  LANES.times do |l|
    (0...WIDTH).each { |x| lines[l][x] = '-' if (x + @frame) % 6 < 3 }
  end

  # Ostacoli
  @obstacles.each do |o|
    sx = o[:x] - @frame
    next unless sx.between?(0, WIDTH - 1)
    lines[o[:lane]][sx]     = '█'
    lines[o[:lane]][sx - 1] = '▌' if sx > 0
  end

  # Macchina
  lines[@lane][CAR_X]     = '▶'
  lines[@lane][CAR_X - 1] = '='
  lines[@lane][CAR_X - 2] = '['

  score_pad = "  Score:#{@score.to_s.rjust(5)}  "

  buf = ""
  # Bordo superiore
  buf += "\e[1;1H#{ROAD_TOP}#{'▓' * (WIDTH + 2)}\e[0m"

  # Corsie
  LANES.times do |l|
    content = lines[l].join[0, WIDTH - score_pad.length] + score_pad
    buf += "\e[#{l + 2};1H#{LANE_BG[l]}\e[97m #{content}\e[0m"
  end

  # Bordo inferiore
  buf += "\e[#{LANES + 2};1H#{ROAD_BOT}#{'▓' * (WIDTH + 2)}\e[0m"

  $stdout.print buf
  $stdout.flush
end

def collision?
  @obstacles.any? do |o|
    o[:lane] == @lane && (o[:x] - @frame).between?(CAR_X - 2, CAR_X)
  end
end

def game_loop
  spawn_obstacle
  spawn_obstacle

  while @running
    sleep 0.07
    @frame += 1

    @obstacles.reject! { |o| o[:x] - @frame < 0 }
    spawn_obstacle if @obstacles.size < 2 || (@obstacles.last[:x] - @frame) < WIDTH

    if collision?
      @running = false
      break
    end

    @score += 1
    render
  end

  mid = (WIDTH / 2) - 12
  msg = " 💥 GAME OVER!  Score: #{@score} "
  LANES.times do |l|
    $stdout.print "\e[#{l + 2};1H\e[41m\e[97m#{' ' * (WIDTH + 2)}\e[0m"
  end
  $stdout.print "\e[#{@lane + 2};#{[mid, 1].max}H\e[41m\e[1m\e[97m#{msg}\e[0m"
  $stdout.flush
end

def input_loop
  rows = IO.console.winsize[0]
  $stdout.print "\e[#{GAME_ROWS + 1};1H"

  while @running
    rows = IO.console.winsize[0]
    print "\e[#{rows};1H\e[K> "
    line = $stdin.gets&.chomp
    break if line.nil?

    rows = IO.console.winsize[0]
    case line.downcase.strip
    when 'w', 'up', 'u', 'su'
      @lane = [@lane - 1, 0].max
      print "\e[#{rows - 1};1H\e[K[corsia #{@lane + 1}]\n"
    when 's', 'down', 'd', 'giu', 'giù'
      @lane = [@lane + 1, LANES - 1].min
      print "\e[#{rows - 1};1H\e[K[corsia #{@lane + 1}]\n"
    when 'quit', 'exit', 'q'
      @running = false
      break
    else
      print "\e[#{rows - 1};1H\e[KHai scritto: #{line}\n"
    end
  end
end

$stdout.print SETUP
$stdout.flush

at_exit do
  $stdout.print TEARDOWN
  $stdout.flush
  puts "\n\nUscito. Score finale: #{@score}"
end

trap('INT') { @running = false }

game_thread = Thread.new { game_loop }

begin
  input_loop
rescue StandardError => e
  @running = false
  $stderr.puts e
end

@running = false
game_thread.join
