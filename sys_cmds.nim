#import strutils
#import os
#import osproc
#import times

# python-style string concatenation
#template `+` (x, y: string): string = x & y

type
  dynStringArray = seq[string]
  App = tuple[passwd: seq[dynStringArray]]

var 
  f: File
  app: App
  dry_run: bool

dry_run = true

#string repetition n times
proc `*` (s:string,n:int): string =
  var repeatedString = ""
  for i in countup(1, n):
    repeatedString = repeatedString & s
  return repeatedString

proc parsepasswd(): int {.discardable.} =
  app.passwd = @[]
  if open(f, "/etc/passwd"):
    for l in f.readAll().strip().split("\n"):
      var indiv: dynStringArray
      indiv = @[]
      for i in l.split(":"):
        indiv.add($i.strip())
      if len(indiv) > 4:
        if len(indiv) < 6:
          indiv = @[]
      app.passwd.add(@indiv)

proc execCmdWrapper(cmd:string, cmdArgs: varargs[string]): int {.discardable.} =
  var
    constructedCmd: string
    errC: int

  constructedCmd = cmd
  for i in items(cmdArgs):
    constructedCmd &= " " & i

  if dry_run: 
    echo "executing cmd: " + $constructedCmd
    return

  errC = execCmd($constructedCmd)
  if errC != 0:
    echo "error executing cmd " + cmd

proc fullchown(username,path: string): int {.discardable.} =
  execCmdWrapper("chown", "-R", username+":"+username, path)
  
proc fullchmod(mode,path: string): int {.discardable.} =
  execCmdWrapper("chmod", "-R", mode, path)

proc sshkeytext(ssh_public_key: string): string =
  return (join(["# Generated by userify",ssh_public_key, ""],"\n"))

proc sshkey_add(username: string, ssh_public_key: string =""): int {.discardable.} =
  if ssh_public_key == "":
    return
  
  var
    userpath,sshpath,fname,text: string
    f: File

  userpath = "/home/" + username
  sshpath = userpath + "/.ssh/"

  execCmdWrapper("mkdir", sshpath)
  fname = sshpath + "authorized_keys"
  text = sshkeytext(ssh_public_key)
  if not open(f,fname) or (f.readAll() != text):
    if open(f,fname,fmWrite):
      try:
        write(f,text)
      except IOError:
        echo "IOError during file write"
      fullchown(username, sshpath)

proc sanitize_sudoers_filename(username: string): string =
  return ( "/etc/sudoers.d/" + username.replace(
            ",", "-").replace(
            ".", "-").replace(
            "@", "-"))

#TODO getLocalTime is deprecated
proc sudoers_add(username: string, perm:string = ""): int {.discardable.} =
  var 
    old_fname,fname,text: string
    f: File
    t = format(getLocalTime(getTime()), "ddd MMM dd HH:mm:ss yyyy")
  old_fname = "/etc/sudoers.d/" + username
  fname = sanitize_sudoers_filename(username)
  if old_fname != fname and existsFile(old_fname):
    # clean up old sudoers files
    execCmdWrapper("/bin/rm", old_fname)
  text = join(["# Generated by Userify: " & $t & " ",
    username + " " * 10 + perm, ""], "\n")
  if dry_run:
    echo "adding " + username + " to sudoers"
    return
  if not existsFile(fname):
    if open(f,fname,fmWrite):
      try:
        write(f,text)
      except IOError:
        echo "IOError during file write"
      fullchmod("0440",fname)

proc sudoers_del(username: string): int {.discardable.} =
  var fname = sanitize_sudoers_filename(username)
  if existsFile(fname):
    execCmdWrapper("/bin/rm", fname)

proc userdel(username: string, permanent: bool=false): int {.discardable.} =
  # removes user and renames homedir
  var
    removed_dir, home_dir: string

  removed_dir = "/home/deleted:" + username
  home_dir = "/home/" + username
  if not permanent:
    if dirExists(removed_dir):
      execCmdWrapper("/bin/rm", "-Rf", removed_dir)
    # try multiple pkill formats until one works
    # Debian, Ubuntu:
    execCmdWrapper("/usr/bin/pkill", "--signal", "9", "-u", username)
    # RHEL, CentOS, and Amazon Linux:
    execCmdWrapper("/usr/bin/pkill", "-9", "-u", username)
    execCmdWrapper("/usr/sbin/userdel", username)
    execCmdWrapper("/bin/mv", home_dir, removed_dir)
  else:
    execCmdWrapper("/usr/sbin/userdel", "-r", username)
  parsepasswd()

proc useradd(name,username,preferred_shell: string): int {.discardable.}  =
  var
    removed_dir, home_dir, useradd_suffix: string

  removed_dir = "/home/deleted:" + username
  home_dir = "/home/" + username

  #restore removed home directory
  if not dirExists(home_dir) and dirExists(removed_dir):
    execCmdWrapper("/bin/mv", removed_dir, home_dir)
  if dirExists(home_dir):
    useradd_suffix = ""
  else:
    useradd_suffix = "-m"
  execCmdWrapper("/usr/sbin/useradd", useradd_suffix,
                             # UsePAM no should be in /etc/ssh/sshd_config
                             "--comment", "userify-" + name,
                             "-s",  if (preferred_shell != ""): preferred_shell else: "/bin/bash",
                             "--user-group", username)
  fullchown(username,home_dir)
  parsepasswd()

proc remove_user(username: string, permanent: bool=false): int {.discardable.} =
  try: userdel(username, permanent)
  except: echo "userdel operation failed"
  try: sudoers_del(username)
  except: echo "sudoers_del operation failed"

proc system_usernames(): dynStringArray =
  #echo "returns all usernames in /etc/passwd"
  var userNames: dynStringArray
  userNames = @[]
  for i,users in app.passwd:
    userNames.add($users[0])
  return userNames

# TODO 
# current_userify_users only supports returning username
# not entire users depending on passed bool param
# not currently done as return value changes depending on
# passed param.
proc current_userify_users(): dynStringArray =
  #echo "get only usernames created by userify"
  var userify_users: dynStringArray
  userify_users = @[]
  for i,users in app.passwd:
    if (users[4].startswith("userify-")):
      userify_users.add($users[0])
  return userify_users