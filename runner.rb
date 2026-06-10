#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'

WIDTH    = (IO.console&.winsize&.[](1) || 80) - 1
PLAYER_X = 5

# Scrolling parte dalla riga 3 (le prime 2 sono il gioco)
SETUP    = "\e[?25l\e[3;999r"
TEARDOWN = "\e[r\e[?25h"

@running   = true
@jump      = 0   # frame rimanenti del salto (0 = a terra)
@obstacles = []
@frame     = 0
@score     = 0

JUMP_FRAMES = 10  # durata totale salto (andata + ritorno)

def in_air?
  @jump > 0
end

def spawn_obstacle
  last = @obstacles.last || 0
  @obstacles << (last + rand(14..22) + WIDTH)
end

def render
  # Riga ARIA (riga 1): personaggio quando salta, spazi altrimenti
  air = Array.new(WIDTH, ' ')
  air[PLAYER_X] = 'o' if in_air?

  # Riga TERRA (riga 2): pedana, ostacoli, personaggio a terra
  ground = Array.new(WIDTH, '_')
  @obstacles.each do |ox|
    sx = ox - @frame
    if sx.between?(0, WIDTH - 1)
      ground[sx] = '█'
    end
  end
  ground[PLAYER_X] = in_air? ? ' ' : 'O'

  score_tag = " Score:#{@score.to_s.rjust(4)} "

  buf  = "\e[1;1H\e[48;5;236m\e[97m #{air.join[0, WIDTH - score_tag.length - 1]}#{score_tag}\e[0m"
  buf += "\e[2;1H\e[48;5;236m\e[93m #{ground.join[0, WIDTH - score_tag.length - 1]}#{score_tag}\e[0m"
  $stdout.print buf
  $stdout.flush
end

def game_loop
  spawn_obstacle

  while @running
    sleep 0.08
    @frame += 1
    @jump  -= 1 if @jump > 0

    @obstacles.reject! { |ox| ox - @frame < 0 }
    spawn_obstacle if @obstacles.empty? || (@obstacles.last - @frame) < WIDTH

    # Collisione solo quando è a terra
    unless in_air?
      @obstacles.each do |ox|
        if (ox - @frame) == PLAYER_X
          @running = false
          break
        end
      end
    end

    @score += 1
    render
  end

  $stdout.print "\e[1;1H\e[41m\e[97m GAME OVER! Score: #{@score}#{' ' * (WIDTH - 20)} \e[0m"
  $stdout.print "\e[2;1H\e[41m\e[97m#{' ' * WIDTH}\e[0m"
  $stdout.flush
end

def input_loop
  rows = IO.console.winsize[0]
  $stdout.print "\e[3;1H"

  while @running
    print "\e[#{rows};1H\e[K> "
    line = $stdin.gets&.chomp
    break if line.nil?

    rows = IO.console.winsize[0]
    case line.downcase.strip
    when 'jump', 'j', '', ' '
      @jump = JUMP_FRAMES if @jump == 0
      print "\e[#{rows - 1};1H\e[K[salto!]\n"
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
