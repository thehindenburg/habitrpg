content = require('./content')
helpers = require('./helpers')
MODIFIER = .03 # each new level, armor, weapon add 3% modifier (this number may change) 
user = undefined

# This is required by all the functions, make sure it's set before anythign else is called
setUser = (u) ->
  user = u

# FIXME move to index.coffee as module.on('set','*')
statsNotification = (html, type) ->
  #don't show notifications if user dead
  return if user.get('stats.lvl') == 0
  
  $.bootstrapGrowl html, {
    type: type # (null, 'info', 'error', 'success')
    top_offset: 20
    align: 'right' # ('left', 'right', or 'center')
    width: 250 # (integer, or 'auto')
    delay: 3000
    allow_dismiss: true
    stackup_spacing: 10 # spacing between consecutive stacecked growls.
  }
  
# Calculates Exp modification based on weapon & lvl
expModifier = (value) ->
  dmg = user.get('items.weapon') * MODIFIER # each new weapon increases exp gain
  dmg += user.get('stats.lvl') * MODIFIER # same for lvls
  modified = value + (value * dmg)
  return modified

# Calculates HP-loss modification based on armor & lvl
hpModifier = (value) ->
  ac = user.get('items.armor') * MODIFIER # each new armor decreases HP loss
  ac += user.get('stats.lvl') * MODIFIER # same for lvls
  modified = value - (value * ac)
  return modified
  
# Setter for user.stats: handles death, leveling up, etc
updateStats = (stats) ->
  # if user is dead, dont do anything
  return if user.get('stats.lvl') == 0
    
  if stats.hp?
    # game over
    if stats.hp <= 0
      user.set 'stats.lvl', 0 # this signifies dead
      user.set 'stast.hp', 0
      return
    else
      user.set 'stats.hp', stats.hp
      
  if stats.exp?
    # level up & carry-over exp
    tnl = user.get '_tnl'
    if stats.exp >= tnl
      stats.exp -= tnl
      user.set 'stats.lvl', user.get('stats.lvl') + 1
      user.set 'stats.hp', 50
      statsNotification('<i class="icon-chevron-up"></i> Level Up!', 'info')
    if !user.get('items.itemsEnabled') and stats.exp >=15
      user.set 'items.itemsEnabled', true
      $('ul.items').popover
        title: content.items.unlockedMessage.title
        placement: 'left'
        trigger: 'manual'
        html: true
        content: "<div class='item-store-popover'>\
          <img src='/img/BrowserQuest/chest.png' />\
          #{content.items.unlockedMessage.content} <a href='#' onClick=\"$('ul.items').popover('hide');return false;\">[Close]</a>\
          </div>"
      $('ul.items').popover 'show'

    user.set 'stats.exp', stats.exp
    
  if stats.money?
    money = 0.0 if (!money? or money<0)
    user.set 'stats.money', stats.money
    
score = (spec = {task:null, direction:null, cron:null}) ->
  [task, direction, cron] = [spec.task, spec.direction, spec.cron]
  
  # up / down was called by itself, probably as REST from 3rd party service
  if !task
    [money, hp, exp] = [user.get('stats.money'), user.get('stats.hp'), user.get('stats.exp')]
    if (direction == "up")
      modified = expModifier(1)
      money += modified
      exp += modified
      # statsNotification "<i class='icon-star'></i>Exp,GP +#{modified.toFixed(2)}", 'success'
    else
      modified = hpModifier(1)
      hp -= modified
      # statsNotification "<i class='icon-heart'></i>HP #{modified.toFixed(2)}", 'error'
    updateStats({hp: hp, exp: exp, money: money})
    return
    
  
  # For negative values, use a line: something like y=-.1x+1
  # For positibe values, taper off with inverse log: y=.9^x
  # Would love to use inverse log for the whole thing, but after 13 fails it hits infinity
  sign = if (direction == "up") then 1 else -1
  value = task.get('value')
  delta = if (value < 0) then (( -0.1 * value + 1 ) * sign) else (( Math.pow(0.9,value) ) * sign)
  
  type = task.get('type')

  # Don't adjust values for rewards, or for habits that don't have both + and -
  adjustvalue = (type != 'reward')
  if (type == 'habit') and (task.get("up")==false or task.get("down")==false)
    adjustvalue = false
  value += delta if adjustvalue

  if type == 'habit'
    # Add habit value to habit-history (if different)
    task.push 'history', { date: new Date(), value: value } if task.get('value') != value
  task.set('value', value)

  # Update the user's status
  [money, hp, exp, lvl] = [user.get('stats.money'), user.get('stats.hp'), user.get('stats.exp'), user.get('stats.lvl')]

  if type == 'reward'
    # purchase item
    money -= task.get('value')
    num = parseFloat(task.get('value')).toFixed(2)
    statsNotification "<i class='icon-star'></i>GP -#{num}", 'success'
    # if too expensive, reduce health & zero money
    if money < 0
      hp += money# hp - money difference
      statsNotification "<i class='icon-heart'></i>HP #{money.toFixed(2)}", 'error'
      money = 0
      
  # Add points to exp & money if positive delta
  # Only take away mony if it was a mistake (aka, a checkbox)
  if (delta > 0 or ( type in ['daily', 'todo'])) and !cron
    modified = expModifier(delta)
    exp += modified
    money += modified
    if modified > 0
      statsNotification "<i class='icon-star'></i>Exp,GP +#{modified.toFixed(2)}", 'success'
    else
      # unchecking an accidently completed daily/todo
      statsNotification "<i class='icon-star'></i>Exp,GP #{modified.toFixed(2)}", 'warning'
  # Deduct from health (rewards case handled above)
  else unless type in ['reward', 'todo']
    modified = hpModifier(delta)
    hp += modified
    statsNotification "<i class='icon-heart'></i>HP #{modified.toFixed(2)}", 'error'

  updateStats({hp: hp, exp: exp, money: money})
  
  return delta 

cron = ->  
  today = new Date()
  user.setNull('lastCron', today)
  lastCron = user.get('lastCron')
  daysPassed = helpers.daysBetween(lastCron, today)
  if daysPassed > 0
    user.set('lastCron', today) # reset cron
    _(daysPassed).times (n) ->
      tallyFor = moment(lastCron).add('d',n)
      tally(tallyFor)   

# At end of day, add value to all incomplete Daily & Todo tasks (further incentive)
# For incomplete Dailys, deduct experience
tally = (momentDate) ->
  todoTally = 0
  _.each user.get('tasks'), (taskObj, taskId, list) ->
    #FIXME is it hiccuping here? taskId == "$_65255f4e-3728-4d50-bade-3b05633639af_2", & taskObj.id = undefined
    return unless taskObj.id? #this shouldn't be happening, some tasks seem to be corrupted
    [type, value, completed, repeat] = [taskObj.type, taskObj.value, taskObj.completed, taskObj.repeat]
    task = user.at("tasks.#{taskId}")
    if type in ['todo', 'daily']
      # Deduct experience for missed Daily tasks, 
      # but not for Todos (just increase todo's value)
      unless completed
        dayMapping = {0:'su',1:'m',2:'t',3:'w',4:'th',5:'f',6:'s',7:'su'}
        dueToday = (repeat && repeat[dayMapping[momentDate.day()]]==true) 
        if dueToday or type=='todo'
          score({task:task, direction:'down', cron:true})
      if type == 'daily'
        task.push "history", { date: new Date(momentDate), value: value }
      else
        absVal = if (completed) then Math.abs(value) else value
        todoTally += absVal
      task.pass({cron:true}).set('completed', false) if type == 'daily'
  user.push 'history.todos', { date: new Date(momentDate), value: todoTally }
  
  # tally experience
  expTally = user.get 'stats.exp'
  lvl = 0 #iterator
  while lvl < (user.get('stats.lvl')-1)
    lvl++
    expTally += (lvl*100)/5
  user.push 'history.exp',  { date: new Date(), value: expTally } 
  

module.exports = {
  MODIFIER: MODIFIER
  setUser: setUser
  score: score
  cron: cron
}