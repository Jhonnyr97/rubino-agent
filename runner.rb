#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'

# Salva posizione cursore, nasconde cursore, imposta scrolling dalla riga 2
SETUP = "\e[s\e[?25l\e[2;999r"
# Ripristina tutto
TEARDOWN = "\e[r\e[?25h\e[u"

WIDTH = (IO.console&.winsize&.[](1) || 80) - 1

GROUND  = WIDTH - 1
PLAYER_X = 5
JUMP_HEIGHT = 3

@running   = true
@jump      = 0        # frame rimanenti del salto
@obstacles = []       # array di posizioni x
@frame     = 0
@score     = 0

def player_y
  if @jump > 0
    row = JUMP_HEIGHT - ((@jump - 1) % (JUMP_HEIGHT * 2 + 1) - JUMP_HEIGHT).abs
    row = [row, 0].max
    GROUND - row
  else
    GROUND
  end
end

def spawn_obstacle
  last = @obstacles.last || 0
  gap = rand(12..22)
  @obstacles << (last + gap + WIDTH)
end

def render
  # Muovi a riga 1, colonna 1
  row = Array.new(WIDTH + 1, ' ')

  # Terra
  (0..WIDTH).each { |i| row[i] = '_' }

  # Ostacoli (cactus)
  @obstacles.each do |ox|
    sx = ox - @frame
    row[sx] = '|' if sx.between?(0, WIDTH)
  end

  # Personaggio
  py = player_y
  row[PLAYER_X] = py < GROUND ? 'o' : 'O'

  # Costruisci la riga con sfondo colorato
  bar = "\e[1;1H\e[48;5;235m\e[97m" \
        "#{row.join}" \
        "  Score:#{@score.to_s.rjust(4)}" \
        "\e[0m"
  $stdout.print bar
  $stdout.flush
end

def game_loop
  spawn_obstacle

  until !@running
    sleep 0.08

    @frame += 1
    @jump -= 1 if @jump > 0

    # Scorri ostacoli
    @obstacles.reject! { |ox| ox - @frame < 0 }
    spawn_obstacle if @obstacles.empty? || (@obstacles.last - @frame) < WIDTH

    # Collisione
    @obstacles.each do |ox|
      if (ox - @frame) == PLAYER_X && player_y == GROUND
        @running = false
        break
      end
    end

    @score += 1
    render
  end

  # Game over
  $stdout.print "\e[1;1H\e[41m\e[97m GAME OVER! Score: #{@score} — premi INVIO per uscire \e[0m"
  $stdout.flush
end

def input_loop
  $stdout.print "\e[2;1H"  # cursore a riga 2

  while @running
    print "\e[#{IO.console.winsize[0]};1H> "
    line = $stdin.gets&.chomp
    break if line.nil?

    case line.downcase
    when 'jump', 'j', ' ', ''
      @jump = JUMP_HEIGHT * 2 + 1 if @jump == 0
      print "\e[#{IO.console.winsize[0] - 1};1H[saltato!]\n"
    when 'quit', 'exit', 'q'
      @running = false
      break
    else
      rows = IO.console.winsize[0]
      print "\e[#{rows - 1};1HHai scritto: #{line}\n"
    end
  end
end

# Setup terminale
$stdout.print SETUP
$stdout.flush

at_exit do
  $stdout.print TEARDOWN
  $stdout.flush
  puts "\nUscito. Score finale: #{@score}"
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
