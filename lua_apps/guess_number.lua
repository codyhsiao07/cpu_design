-- Interactive UART number-guessing game for the FreeRTOS Lua platform.

local test_secret = rawget(_G, "GAME_TEST_SECRET")
GAME_TEST_SECRET = nil

local secret
if type(test_secret) == "number" and
   test_secret >= 1 and test_secret <= 20 then
    secret = math.floor(test_secret)
else
    secret = (rtos.tick() % 20) + 1
end

local attempts = 0
local max_attempts = 6

print("=== FPGA Lua Number Guess ===")
print("Guess an integer from 1 to 20.")
print("GAME_READY range=1..20 attempts=6")

while attempts < max_attempts do
    print("GAME_PROMPT next_attempt=", attempts + 1)
    local text, reason = rtos.read_line(60000)

    if text == nil then
        print("GAME_INPUT_TIMEOUT", reason)
        return
    end

    local guess = tonumber(text)
    if guess == nil or math.floor(guess) ~= guess or
       guess < 1 or guess > 20 then
        print("GAME_INVALID enter=1..20")
    else
        attempts = attempts + 1
        if guess < secret then
            print("GAME_LOW", guess)
        elseif guess > secret then
            print("GAME_HIGH", guess)
        else
            print("GAME_WIN attempts=", attempts)
            return
        end
    end
end

print("GAME_OVER secret=", secret)
