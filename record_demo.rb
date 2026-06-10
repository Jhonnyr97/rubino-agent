#!/usr/bin/env ruby
# Demo headless del runner a 2 righe per asciinema

WIDTH    = 78
PLAYER_X = 5
JUMP_FRAMES = 10

@frame     = 0
@jump      = 0
@obstacles = []
@score     = 0

def in_air? = @jump > 0

def spawn_obstacle
  last = @obstacles.last || 0
  @obstacles << (last + rand(14..20) + WIDTH)
end

def render
  air    = Array.new(WIDTH, ' ')
  ground = Array.new(WIDTH, '_')

  air[PLAYER_X]    = 'o' if in_air?
  ground[PLAYER_X] = in_air? ? ' ' : 'O'

  @obstacles.each do |ox|
    sx = ox - @frame
    ground[sx] = '█' if sx.between?(0, WIDTH - 1)
  end

  score_tag = " Score:#{@score.to_s.rjust(4)} "
  w = WIDTH - score_tag.length - 1

  buf  = "\e[1;1H\e[48;5;236m\e[97m #{air.join[0, w]}#{score_tag}\e[0m"
  buf += "\e[2;1H\e[48;5;236m\e[93m #{ground.join[0, w]}#{score_tag}\e[0m"
  $stdout.print buf
  $stdout.flush
end

print "\e[?25l\e[3;99r"
print "\e[3;1H\e[2mdigita 'jump' + INVIO per saltare, 'quit' per uscire\e[0m"

spawn_obstacle

auto_jumps = [15, 33, 52, 70, 88]
total_frames = 105

total_frames.times do |i|
  @frame += 1
  @jump  -= 1 if @jump > 0

  @obstacles.reject! { |ox| ox - @frame < 0 }
  spawn_obstacle if @obstacles.empty? || (@obstacles.last - @frame) < WIDTH

  @jump = JUMP_FRAMES if auto_jumps.include?(i) && @jump == 0

  @score += 1
  render

  if auto_jumps.include?(i)
    print "\e[4;1H\e[K> jump"
    $stdout.flush
  elsif i % 35 == 0
    print "\e[4;1H\e[K> ciao, scrivo normalmente qui sotto..."
    $stdout.flush
  end

  sleep 0.09
end

print "\e[1;1H\e[42m\e[97m Demo finita! Score: #{@score} \e[0m"
print "\e[2;1H\e[42m\e[97m#{' ' * WIDTH}\e[0m"
print "\e[?25h\e[r"
$stdout.flush
sleep 0.8
