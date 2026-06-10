#!/usr/bin/env ruby
# Versione headless/demo del runner per la registrazione asciinema
# Simula 5 secondi di gioco con 2 salti automatici

require 'io/console'

WIDTH = 78
GROUND = 1   # riga di terra (0-indexed dall'alto, nella barra è sempre riga 0)
PLAYER_X = 5
JUMP_HEIGHT = 3

@frame     = 0
@jump      = 0
@obstacles = []
@score     = 0

def player_row
  if @jump > 0
    h = JUMP_HEIGHT - ((@jump - 1) % (JUMP_HEIGHT * 2 + 1) - JUMP_HEIGHT).abs
    h = [h, 0].max
    h   # righe sopra il suolo
  else
    0
  end
end

def spawn_obstacle
  last = @obstacles.last || 0
  gap  = rand(14..20)
  @obstacles << (last + gap + WIDTH)
end

def render_bar
  row = Array.new(WIDTH + 2, '_')

  # ostacoli
  @obstacles.each do |ox|
    sx = ox - @frame
    row[sx] = '|' if sx.between?(0, WIDTH)
  end

  # personaggio — sale sopra il suolo
  pr = player_row
  ch = pr > 0 ? 'o' : 'O'
  # la "riga" è una sola linea; mostriamo il salto alzando il carattere
  # ma siccome abbiamo 1 linea usiamo solo il simbolo diverso
  row[PLAYER_X] = ch

  "\e[1;1H\e[48;5;235m\e[97m#{row.join[0, WIDTH]}  Score:#{@score.to_s.rjust(4)}\e[0m"
end

# Setup: scroll da riga 2 in giù, nascondi cursore
print "\e[?25l\e[2;99r"

# Riga 2: istruzioni fisse
print "\e[2;1H\e[2mdigita 'jump' + INVIO per saltare, 'quit' per uscire\e[0m"

spawn_obstacle

auto_jumps = [18, 36, 54, 72, 90]   # frame in cui il demo salta da solo
total_frames = 100

total_frames.times do |i|
  @frame += 1
  @jump  -= 1 if @jump > 0

  @obstacles.reject! { |ox| ox - @frame < 0 }
  spawn_obstacle if @obstacles.empty? || (@obstacles.last - @frame) < WIDTH

  # salto automatico
  @jump = JUMP_HEIGHT * 2 + 1 if auto_jumps.include?(i) && @jump == 0

  @score += 1

  print render_bar

  # Stampa un messaggio di "input" ogni tanto
  if auto_jumps.include?(i)
    print "\e[3;1H\e[K> jump"
  elsif i % 30 == 0 && !auto_jumps.include?(i)
    print "\e[3;1H\e[K> ciao, sto scrivendo normalmente..."
  end

  $stdout.flush
  sleep 0.09
end

print "\e[1;1H\e[42m\e[97m Demo finita! Score: #{@score} \e[0m"
print "\e[?25h\e[r"
$stdout.flush
sleep 0.5
