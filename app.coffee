# Requires
pathUtil = require('path')
fsUtil = require('fs')
balUtil = require('bal-util')
safefs = require('safefs')
safeps = require('safeps')
eachr = require('eachr')
commander = require('commander')
{TaskGroup} = require('taskgroup')
exchange = require('./exchange')



# -----------------
# App

class App
	runner: null
	config: null
	logger: null

	constructor: (@config) ->
		# Prepare
		me = @

		# Logger
		level    = if @config.debug then 7 else 6
		@logger  = require('caterpillar').createLogger({level:level})
		filter   = require('caterpillar-filter').createFilter()
		human    = require('caterpillar-human').createHuman()
		@logger.pipe(filter).pipe(human).pipe(process.stdout)

		# Runner
		@runner = new TaskGroup().run().on 'complete', (err) ->
			console.log(err.stack)  if err

	log: (args...) ->
		logger = (@logger or console)
		logger.log.apply(logger, args)

	ensure: (opts,next) ->
		{skeletonsPath, pluginsPath} = @config

		@runner.addGroup 'ensure tasks', ->
			@addTask 'plugins path', (complete) -> safefs.ensurePath(pluginsPath, complete)
			@addTask 'skeletons path', (complete) -> safefs.ensurePath(skeletonsPath, complete)

		@runner.addTask(next)  if next
		@

	clone: (opts,next) ->
		me = @
		{skeletonsPath, pluginsPath} = @config

		@runner.addGroup 'clone tasks', ->
			# Skeletons
			@addTask 'skeletons task', (complete) ->
				me.log 'info', "Cloning latest skeletons"

				cloneRepos = []
				for own key,repo of exchange.skeletons
					repoShortname = repo.repo.replace(/^.+\/(.+\/.+)\.git$/, '$1').replace('/', '-')
					cloneRepos.push(
						name: key
						url: repo.repo
						path: "#{skeletonsPath}/#{repoShortname}"
						branch: repo.branch
					)

				# Clone the repos
				me.cloneRepos({repos: cloneRepos}, complete)

			# Plugins
			@addTask 'plugins task', (complete) ->
				me.log 'info', "Fetching latest plugins"
				balUtil.readPath "https://api.github.com/orgs/docpad/repos?page=1&per_page=100", (err,data) ->
					# Check
					return next(err)  if err

					# Invalid JSON
					try
						repos = JSON.parse(data)
					catch err
						return complete(err)

					# Error Message
					if repos.message
						err = new Error(repos.message)
						return complete(err)

					# No repos
					if repos.length is 0
						return complete()

					# Skip if not a plugin
					cloneRepos = []
					repos.forEach (repo) ->
						# Prepare
						repoShortname = repo.name.replace(/^docpad-plugin-/,'')

						# Skip if expiremental or deprecated or is not a plugin
						return  if /^(EXPER|DEPR)/.test(repo.description) or repoShortname is repo.name

						# Add the repo to the ones we want to clone
						cloneRepos.push(
							name: repo.name
							url: repo.clone_url
							path: "#{pluginsPath}/#{repoShortname}"
							branch: 'master'
						)

					# Log
					me.log 'info', "Cloning latest plugins"

					# Clone the repos
					me.cloneRepos({repos: cloneRepos}, complete)

		@runner.addTask(next)  if next
		@

	cloneRepos: (opts,next) ->
		# Prepare
		me = @
		cloneTasks = new TaskGroup().setConfig(concurrency:1).once('complete',next)

		# Clone each one
		eachr opts.repos, (repo) ->
			# Prepare
			spawnCommands = []
			spawnOpts = {}

			# New
			if fsUtil.existsSync(repo.path) is false
				spawnCommands.push ['git', 'clone', repo.url, repo.path]

			# Update
			else
				spawnCommands.push ['git', 'checkout', repo.branch]
				spawnCommands.push ['git', 'pull', 'origin', repo.branch]
				spawnOpts.cwd = repo.path

			# Re-link
			spawnCommands.push ['npm', 'link', 'docpad']

			# Handle
			cloneTasks.addTask (next) ->
				me.log 'info', "Fetching #{repo.name}"
				safeps.spawnMultiple spawnCommands, spawnOpts, (err,args...) ->
					if err
						me.log 'info', "Fetching #{repo.name} FAILED", err
						return next(err)
					else
						me.log 'info', "Fetched #{repo.name}"
					return next()

		# Run
		cloneTasks.run()

	status: (opts,next) ->
		me = @
		{pluginsPath} = @config
		{skip,only} = (opts or {skip:null,only:null})

		@runner.addTask (next) ->
			# Scan Plugins
			balUtil.scandir(
				# Path
				pluginsPath

				# Skip files
				false

				# Handle directories
				(pluginPath,pluginRelativePath,nextFile) ->
					# Prepare
					pluginName = pathUtil.basename(pluginRelativePath)

					# Skip
					if skip and (pluginName in skip)
						me.log('info', "Skipping #{pluginName}")
						return
					if only and (pluginName in only) is false
						me.log('info', "Skipping #{pluginName}")
						return

					# Execute the plugin's tests
					options = {cwd:pluginPath, env:process.env}
					safeps.spawnCommand 'git', ['status'], options, (err,stdout,stderr) ->
						# Log
						if stdout and stdout.indexOf('nothing to commit') is -1
							me.log 'info', pluginPath  if stdout or stderr
							me.log 'info', stdout  if stdout
							me.log 'info', stderr  if stderr

						# Done
						nextFile(err,true)

				# Finish
				(err,list,tree) ->
					return next(err)
			)

		@runner.addTask(next)  if next
		@

	outdated: (opts,next) ->
		me = @
		{npmEdgePath,pluginsPath} = @config
		{skip,only} = (opts or {skip:null,only:null})

		@runner.addTask (next) ->
			# Scan Plugins
			balUtil.scandir(
				# Path
				pluginsPath

				# Skip files
				false

				# Handle directories
				(pluginPath,pluginRelativePath,nextFile) ->
					# Prepare
					pluginName = pathUtil.basename(pluginRelativePath)

					# Skip
					if skip and (pluginName in skip)
						me.log('info', "Skipping #{pluginName}")
						return
					if only and (pluginName in only) is false
						me.log('info', "Skipping #{pluginName}")
						return

					# Execute the plugin's tests
					command = npmEdgePath
					options = {cwd:pluginPath}
					safeps.spawnCommand 'node', command, options, (err,stdout,stderr) ->
						# Log
						if stdout and stdout.indexOf('is specified') isnt -1
							me.log 'info', pluginPath  if stdout or stderr
							me.log 'info', stdout.replace(/^npm http .*/m, '')  if stdout
							me.log 'info', stderr  if stderr

						# Done
						nextFile(err,true)

				# Finish
				next
			)

		@runner.addTask(next)  if next
		@

	standardize: (opts,next) ->
		me = @
		{pluginsPath} = @config

		@runner.addTask (next) ->
			standardizeTasks = new TaskGroup(concurrency:1).once('complete', next)

			# Scan Plugins
			balUtil.scandir(
				# Path
				pluginsPath

				# Skip files
				false

				# Handle directories
				(pluginPath,pluginRelativePath,nextFile) ->  nextFile(null,true); standardizeTasks.addTask (complete) ->
					# Prepare
					pluginName = pathUtil.basename(pluginRelativePath)

					me.log 'debug', "Standardize #{pluginName}: rename contributing"
					safeps.spawnCommand 'git', ['mv','-f','-k','Contributing.md','CONTRIBUTING.md'], {cwd:pluginPath,output:true}, (err) ->
						return complete(err)  if err

						me.log 'debug', "Standardize #{pluginName}: rename history"
						safeps.spawnCommand 'git', ['mv','-f','-k','History.md','HISTORY.md'], {cwd:pluginPath,output:true}, (err) ->
							return complete(err)  if err

							me.log 'debug', "Standardize #{pluginName}: download meta files"
							safeps.exec pathUtil.join(__dirname, 'download-meta.bash'), {cwd:pluginPath,output:true}, (err) ->
								return complete(err)  if err

								# Update the package.json file
								pluginPackagePath = pluginPath+'/package.json'
								pluginPackageData = require(pluginPackagePath)

								engines = (pluginPackageData.engines ?= {})
								peerDeps = (pluginPackageData.peerDependencies ?= {})
								devDeps = (pluginPackageData.devDependencies ?= {})

								devDeps.docpad = (peerDeps.docpad ?= engines.docpad ? '6')
								delete engines.docpad
								devDeps.projectz = '~0.3.9'

								pluginPackageData.bugs.url = "https://github.com/docpad/docpad-plugin-#{pluginName}/issues"
								pluginPackageData.repository.url = "https://github.com/docpad/docpad-plugin-#{pluginName}.git"
								pluginPackageData.license = 'MIT'
								pluginPackageData.badges = {
									"travis": true
									"npm": true
									"david": true
									"daviddev": true
									"gittip": "docpad"
									"flattr": "344188/balupton-on-Flattr"
									"paypal": "QB8GQPZAH84N6"
									"bitcoin": "https://coinbase.com/checkouts/9ef59f5479eec1d97d63382c9ebcb93a"
								}

								me.log 'debug', "Standardize #{pluginName}: write package"
								pluginPackageDataString = JSON.stringify(pluginPackageData, null, '  ')
								safefs.writeFile pluginPackagePath, pluginPackageDataString, (err) ->
									return complete(err)  if err

									me.log 'debug', "Standardize #{pluginName}: prepublish"
									cakePath = pathUtil.join(pluginPath, 'node_modules', '.bin', 'cake')
									safeps.spawn [cakePath, 'prepublish'], {cwd:pluginPath,output:true,outputPrefix: '>	'}, (err) ->
										return complete(err)

				# Finish
				(err) ->
					return next(err)  if err
					return standardizeTasks.run()
			)

		@runner.addTask(next)  if next
		@

	exec: (opts,next) ->
		me = @
		{pluginsPath} = @config

		@runner.addTask (next) ->
			# Scan Plugins
			balUtil.scandir(
				# Path
				pluginsPath

				# Skip files
				false

				# Handle directories
				(pluginPath,pluginRelativePath,nextFile) ->
					# Prepare
					pluginName = pathUtil.basename(pluginRelativePath)

					# Execute the command
					safeps.exec opts.command, {cwd:pluginPath, env: process.env}, (err, stdout, stderr) ->
						me.log 'info', "exec [#{opts.command}] on: #{pluginPath}"
						process.stdout.write stderr  if err
						process.stdout.write stdout
						me.log 'info', ''
						return nextFile(err, true)

				# Finish
				next
			)

		@runner.addTask(next)  if next
		@

	test: (opts,next) ->
		me = @
		{pluginsPath} = @config
		{skip,only,startFrom} = (opts or {})

		@runner.addTask (next) ->
			# Require Joe Testing Framework
			joe = require('joe')

			# Start playing eye of the tiger
			require('open')('http://youtu.be/2WrEmJpV2ic')

			# Scan Plugins
			balUtil.scandir(
				# Path
				pluginsPath

				# Skip files
				false

				# Handle directories
				(pluginPath,pluginRelativePath,nextFile) ->
					# Prepare
					pluginName = pathUtil.basename(pluginRelativePath)

					# Skip
					if startFrom and startFrom > pluginName
						me.log('info', "Skipping #{pluginName}")
						return
					if skip and (pluginName in skip)
						me.log('info', "Skipping #{pluginName}")
						return
					if only and (pluginName in only) is false
						me.log('info', "Skipping #{pluginName}")
						return
					if fsUtil.existsSync(pluginPath+'/test') is false
						me.log('info', "Skipping #{pluginName}")
						return

					# Test the plugin
					joe.test pluginName, (done) ->
						# Prepare
						options = {output:true,cwd:pluginPath}

						# Commands
						spawnCommands = []
						spawnCommands.push('npm link docpad')
						spawnCommands.push('npm install')
						if fsUtil.existsSync(pluginPath+'/Cakefile')
							spawnCommands.push('cake compile')
						else if fsUtil.existsSync(pluginPath+'/Makefile')
							spawnCommands.push('make compile')
						spawnCommands.push('npm test')

						# Spawn
						safeps.spawnMultiple spawnCommands, options, (err,results) ->
							# Output the test results for the plugin
							if results.length is spawnCommands.length
								testResult = results[spawnCommands.length-1]
								err = testResult[0]
								# args = testResult[1...]
								if err
									joeError = new Error("Testing #{pluginName} FAILED")
									# me.log 'info', "Testing #{pluginName} FAILED"
									# args.forEach (arg) -> me.log('info', arg)  if arg
									done(joeError)
								else
									done()
							else
								done()

							# All done
							nextFile(err, true)

				# Finish
				next
			)

		@runner.addTask(next)  if next
		@

# -----------------
# Helpers

# Handle CSV values
splitCsvValue = (result) ->
	result or= ''
	result = result.split(',')  if result
	result or= null
	return result


# -----------------
# Commands

## Commands

# Use [Commander](https://github.com/visionmedia/commander.js/) for command and option parsing
cli = require('commander')

# Extract out version out of our package and apply it to commander
cli.version(
	require('./package.json').version
)

# Options
cli
	.option('--only <only>', 'only run against these plugins (CSV)')
	.option('--skip <skip>', 'skip these plugins (CSV)')
	.option('--start <start>', 'start from this plugin name')
	.option('-d, --debug', 'output debug messages')

# exec
cli.command('exec <command>').description('execute a command for each plugin').action (command) ->  process.nextTick ->
	app.exec({command})

# outdated
cli.command('outdated').description('check which plugins have outdated dependencies')
	.action ->  process.nextTick ->
		app.status({
			only: splitCsvValue(cli.only)
			skip: splitCsvValue(cli.skip) or defaultSkip
			startFrom: cli.start
		})

# standardize
cli.command('standardize').description('ensure plugins live up to the latest standards').action ->  process.nextTick ->
	app.standardize()

# clone
cli.command('clone').description('clone out new plugins and update the old').action ->  process.nextTick ->
	app.clone()

# status
cli.command('status').description('check the git status of our plugins')
	.action ->  process.nextTick ->
		app.status({
			only: splitCsvValue(cli.only)
			skip: splitCsvValue(cli.skip) or defaultSkip
			startFrom: cli.start
		})

# test
cli.command('test').description('run the tests')
	.action ->  process.nextTick ->
		app.test({
			only: splitCsvValue(cli.only)
			skip: splitCsvValue(cli.skip) or defaultSkip
			startFrom: cli.start
		})

# Start the CLI
cli.parse(process.argv)

# App
app = new App({
	npmEdgePath: pathUtil.join(__dirname, 'node_modules', 'npmedge', 'bin', 'npmedge')
	pluginsPath: pathUtil.join(__dirname, 'plugins')
	skeletonsPath: pathUtil.join(__dirname, 'skeletons')
	debug: cli.debug
}).ensure()
defaultSkip = ['pygments','concatmin','iis','html2jade','html2coffee','tumblr','contenttypes']