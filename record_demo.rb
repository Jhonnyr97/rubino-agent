#!/usr/bin/env ruby
# Demo headless per asciinema — macchina che schiva ostacoli

WIDTH  = 76
LANES  = 3
CAR_X  = 6
GAME_ROWS = LANES + 2

@frame     = 0
@lane      = 1
@obstacles = []
@score     = 0

def spawn_obstacle
  last_x    = @obstacles.map { |o| o[:x] }.max || 0
  used_lane = @obstacles.last&.dig(:lane)
  lane      = ([0, 1, 2] - [used_lane]).sample
  @obstacles << { x: [last_x + rand(10..18) + WIDTH, WIDTH + 5].max, lane: lane }
end

LANE_BG = ["\e[48;5;236m", "\e[48;5;238m", "\e[48;5;236m"]

def render
  lines = Array.new(LANES) { Array.new(WIDTH, ' ') }

  LANES.times do |l|
    (0...WIDTH).each { |x| lines[l][x] = '-' if (x + @frame) % 6 < 3 }
  end

  @obstacles.each do |o|
    sx = o[:x] - @frame
    next unless sx.between?(0, WIDTH - 1)
    lines[o[:lane]][sx]     = '█'
    lines[o[:lane]][sx - 1] = '▌' if sx > 0
  end

  lines[@lane][CAR_X]     = '▶'
  lines[@lane][CAR_X - 1] = '='
  lines[@lane][CAR_X - 2] = '['

  score_pad = "  Score:#{@score.to_s.rjust(5)}  "

  buf = "\e[1;1H\e[48;5;240m\e[90m#{'▓' * (WIDTH + 2)}\e[0m"
  LANES.times do |l|
    content = lines[l].join[0, WIDTH - score_pad.length] + score_pad
    buf += "\e[#{l + 2};1H#{LANE_BG[l]}\e[97m #{content}\e[0m"
  end
  buf += "\e[#{LANES + 2};1H\e[48;5;240m\e[90m#{'▓' * (WIDTH + 2)}\e[0m"

  $stdout.print buf
  $stdout.flush
end

# AI semplice: se c'è un ostacolo in avvicinamento nella mia corsia, cambia
def ai_dodge
  danger = @obstacles.select do |o|
    o[:lane] == @lane && (o[:x] - @frame).between?(8, 20)
  end
  return if danger.empty?

  safe_lanes = (0...LANES).to_a - [danger.first[:lane]]
  # scegli la corsia più vicina tra quelle sicure
  safe_lane = safe_lanes.min_by { |l| (l - @lane).abs }
  @lane = safe_lane if safe_lane
end

print "\e[?25l\e[#{GAME_ROWS + 1};99r"
print "\e[#{GAME_ROWS + 1};1H\e[2mcomandi: 'w'=su  's'=giù  'q'=esci\e[0m"

spawn_obstacle
spawn_obstacle

120.times do |i|
  @frame += 1

  @obstacles.reject! { |o| o[:x] - @frame < 0 }
  spawn_obstacle if @obstacles.size < 2 || (@obstacles.last[:x] - @frame) < WIDTH

  ai_dodge if i % 2 == 0  # controllo ogni 2 frame

  @score += 1
  render

  # Mostra "input" simulato quando cambia corsia
  if i % 25 == 0
    dir = @lane < 1 ? 's' : (@lane > 1 ? 'w' : ['w','s'].sample)
    print "\e[#{GAME_ROWS + 2};1H\e[K> #{dir}"
    $stdout.flush
  end

  sleep 0.08
end

LANES.times do |l|
  $stdout.print "\e[#{l + 2};1H\e[42m\e[97m#{'  ' * ((WIDTH + 2) / 2)}\e[0m"
end
$stdout.print "\e[3;1H\e[42m\e[1m\e[97m   🏁 Demo finita!  Score: #{@score}   \e[0m"
print "\e[?25h\e[r"
$stdout.flush
sleep 1
