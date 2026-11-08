package states;

import sys.thread.FixedThreadPool;
import haxe.Json;
import lime.utils.Assets;
import openfl.display.BitmapData;
import openfl.utils.AssetType;
import openfl.utils.Assets as OpenFlAssets;
import flixel.graphics.FlxGraphic;
import flixel.system.FlxAssets;
import flixel.FlxState;

import flash.media.Sound;

import backend.Song;
import backend.StageData;
import objects.Character;

import sys.thread.Thread;
import sys.thread.Mutex;

import objects.Note;
import objects.NoteSplash;

#if HSCRIPT_ALLOWED
import psychlua.HScript;
import crowplexus.iris.Iris;
import crowplexus.hscript.Expr.Error as IrisError;
import crowplexus.hscript.Printer;
#end

#if cpp
@:headerCode('
#include <iostream>
#include <thread>
')
#end
class LoadingState extends MusicBeatState
{
	public static var loaded:Int = 0;
	public static var loadMax:Int = 0;

	/** Failures recorded by workers during the last loading operation (never silently swallowed). */
	public static var errors:Array<String> = [];

	/** Hard limit for one loading operation. After this the engine falls back to lazy loading. */
	static inline var LOAD_TIMEOUT:Float = 120;
	/** Max seconds per checkLoaded() call spent on main-thread texture registration. */
	static inline var COMMIT_BUDGET:Float = 0.008;

	// One lock protects every static below that workers touch.
	static final lock:Mutex = new Mutex();

	// worker -> main hand-off (guarded by `lock`)
	static var requestedBitmaps:Map<String, BitmapData> = [];
	static var originalBitmapKeys:Map<String, String> = [];
	static var requestedSounds:Map<String, Sound> = [];

	// main-thread only
	static var commitBitmaps:Array<PendingBitmap> = [];
	static var commitSounds:Array<PendingSound> = [];

	// snapshots taken on the main thread so workers never read Paths' live maps
	static var knownImages:Map<String, Bool> = [];
	static var knownSounds:Map<String, Bool> = [];

	static var threadPool:FixedThreadPool = null;
	static var generation:Int = 0;
	static var deadline:Float = 0;
	static var levelApplied:Bool = false;

	function new(target:FlxState, stopMusic:Bool)
	{
		this.target = target;
		this.stopMusic = stopMusic;
		
		super();
	}

	inline static public function loadAndSwitchState(target:FlxState, stopMusic = false, intrusive:Bool = true)
		MusicBeatState.switchState(getNextState(target, stopMusic, intrusive));
	
	var target:FlxState = null;
	var stopMusic:Bool = false;
	var dontUpdate:Bool = false;

	var barGroup:FlxSpriteGroup;
	var bar:FlxSprite;
	var barWidth:Int = 0;
	var intendedPercent:Float = 0;
	var curPercent:Float = 0;
	var stateChangeDelay:Float = 0;

	#if PSYCH_WATERMARKS
	var logo:FlxSprite;
	var pessy:FlxSprite;
	var loadingText:FlxText;

	var timePassed:Float;
	var shakeFl:Float;
	var shakeMult:Float = 0;
	
	var isSpinning:Bool = false;
	var spawnedPessy:Bool = false;
	var pressedTimes:Int = 0;
	#else
	var funkay:FlxSprite;
	#end

	#if HSCRIPT_ALLOWED
	var hscript:HScript;
	#end
	override function create()
	{
		persistentUpdate = true;
		barGroup = new FlxSpriteGroup();
		add(barGroup);

		var barBack:FlxSprite = new FlxSprite(0, 660).makeGraphic(1, 1, FlxColor.BLACK);
		barBack.scale.set(FlxG.width - 300, 25);
		barBack.updateHitbox();
		barBack.screenCenter(X);
		barGroup.add(barBack);

		bar = new FlxSprite(barBack.x + 5, barBack.y + 5).makeGraphic(1, 1, FlxColor.WHITE);
		bar.scale.set(0, 15);
		bar.updateHitbox();
		barGroup.add(bar);
		barWidth = Std.int(barBack.width - 10);

		#if HSCRIPT_ALLOWED
		if(Mods.currentModDirectory != null && Mods.currentModDirectory.trim().length > 0)
		{
			var scriptPath:String = 'mods/${Mods.currentModDirectory}/data/LoadingScreen.hx'; //mods/My-Mod/data/LoadingScreen.hx
			if(FileSystem.exists(scriptPath))
			{
				try
				{
					hscript = new HScript(null, scriptPath);
					hscript.set('getLoaded', function() return loaded);
					hscript.set('getLoadMax', function() return loadMax);
					hscript.set('barBack', barBack);
					hscript.set('bar', bar);
	
					if(hscript.exists('onCreate'))
					{
						hscript.call('onCreate');
						trace('initialized hscript interp successfully: $scriptPath');
						return super.create();
					}
					else
					{
						trace('"$scriptPath" contains no \"onCreate" function, stopping script.');
					}
				}
				catch(e:IrisError)
				{
					var pos:HScriptInfos = cast {fileName: scriptPath, showLine: false};
					Iris.error(Printer.errorToString(e, false), pos);
					var hscript:HScript = cast (Iris.instances.get(scriptPath), HScript);
				}
				if(hscript != null) hscript.destroy();
				hscript = null;
			}
		}
		#end

		#if PSYCH_WATERMARKS // PSYCH LOADING SCREEN
		var bg = new FlxSprite().loadGraphic(Paths.image('menuDesat'));
		bg.antialiasing = ClientPrefs.data.antialiasing;
		bg.setGraphicSize(Std.int(FlxG.width));
		bg.color = 0xFFD16FFF;
		bg.updateHitbox();
		addBehindBar(bg);
	
		loadingText = new FlxText(520, 600, 400, Language.getPhrase('now_loading', 'Now Loading', ['...']), 32);
		loadingText.setFormat(Paths.font("vcr.ttf"), 32, FlxColor.WHITE, LEFT, OUTLINE_FAST, FlxColor.BLACK);
		loadingText.borderSize = 2;
		addBehindBar(loadingText);
	
		logo = new FlxSprite(0, 0).loadGraphic(Paths.image('loading_screen/icon'));
		logo.antialiasing = ClientPrefs.data.antialiasing;
		logo.scale.set(0.75, 0.75);
		logo.updateHitbox();
		logo.screenCenter();
		logo.x -= 50;
		logo.y -= 40;
		addBehindBar(logo);

		#else // BASE GAME LOADING SCREEN
		var bg = new FlxSprite().makeGraphic(1, 1, 0xFFCAFF4D);
		bg.scale.set(FlxG.width, FlxG.height);
		bg.updateHitbox();
		bg.screenCenter();
		addBehindBar(bg);

		funkay = new FlxSprite(0, 0).loadGraphic(Paths.image('funkay'));
		funkay.antialiasing = ClientPrefs.data.antialiasing;
		funkay.setGraphicSize(0, FlxG.height);
		funkay.updateHitbox();
		addBehindBar(funkay);
		#end
		super.create();

		if (stateChangeDelay <= 0 && checkLoaded())
		{
			dontUpdate = true;
			onLoad();
		}
	}

	function addBehindBar(obj:flixel.FlxBasic)
	{
		insert(members.indexOf(barGroup), obj);
	}

	var transitioning:Bool = false;
	override function update(elapsed:Float)
	{
		super.update(elapsed);
		if (dontUpdate) return;

		if (!transitioning)
		{
			if (!finishedLoading && checkLoaded())
			{
				if(stateChangeDelay <= 0)
				{
					transitioning = true;
					onLoad();
					return;
				}
				else stateChangeDelay = Math.max(0, stateChangeDelay - elapsed);
			}
			// C9: never divide by zero (loadMax stays 0 while the manifest is still being prepared)
			intendedPercent = (loadMax > 0) ? Math.min(1, loaded / loadMax) : (initialThreadCompleted ? 1 : 0);
		}

		if (Math.isNaN(curPercent)) curPercent = 0;
		if (curPercent != intendedPercent)
		{
			if (Math.abs(curPercent - intendedPercent) < 0.001) curPercent = intendedPercent;
			else curPercent = FlxMath.lerp(intendedPercent, curPercent, Math.exp(-elapsed * 15));

			bar.scale.x = barWidth * curPercent;
			bar.updateHitbox();
		}
		
		#if HSCRIPT_ALLOWED
		if(hscript != null)
		{
			if(hscript.exists('onUpdate')) hscript.call('onUpdate', [elapsed]);
			return;
		}
		#end

		#if PSYCH_WATERMARKS // PSYCH LOADING SCREEN
		timePassed += elapsed;
		shakeFl += elapsed * 3000;
		var dots:String = '';
		switch(Math.floor(timePassed % 1 * 3))
		{
			case 0:
				dots = '.';
			case 1:
				dots = '..';
			case 2:
				dots = '...';
		}
		loadingText.text = Language.getPhrase('now_loading', 'Now Loading{1}', [dots]);

		if(!spawnedPessy)
		{
			if(!transitioning && controls.ACCEPT)
			{
				shakeMult = 1;
				FlxG.sound.play(Paths.sound('cancelMenu'));
				pressedTimes++;
			}
			shakeMult = Math.max(0, shakeMult - elapsed * 5);
			logo.offset.x = Math.sin(shakeFl * Math.PI / 180) * shakeMult * 100;

			if(pressedTimes >= 5)
			{
				FlxG.camera.fade(0xAAFFFFFF, 0.5, true);
				logo.visible = false;
				spawnedPessy = true;
				stateChangeDelay = 5;
				FlxG.sound.play(Paths.sound('secret'));

				pessy = new FlxSprite(700, 140);
				pessy.frames = Paths.getSparrowAtlas('loading_screen/pessy');
				pessy.animation.addByPrefix('run', 'run', 24, true);
				pessy.animation.addByPrefix('spin', 'spin', 24, true);
				pessy.antialiasing = ClientPrefs.data.antialiasing;
				pessy.flipX = (logo.offset.x > 0);
				pessy.visible = false;

				new FlxTimer().start(0.01, function(tmr:FlxTimer) {
					pessy.x = FlxG.width + 200;
					pessy.velocity.x = -1100;
					if(pessy.flipX)
					{
						pessy.x = -pessy.width - 200;
						pessy.velocity.x *= -1;
					}
		
					pessy.visible = true;
					pessy.animation.play('run', true);
					#if ACHIEVEMENTS_ALLOWED Achievements.unlock('pessy_easter_egg'); #end
					
					insert(members.indexOf(loadingText), pessy);
				});
			}
		}
		else if(!isSpinning && (pessy.flipX && pessy.x > FlxG.width) || (!pessy.flipX && pessy.x < -pessy.width))
		{
			isSpinning = true;
			pessy.animation.play('spin', true);
			pessy.flipX = false;
			pessy.x = 500;
			pessy.y = FlxG.height + 500;
			pessy.velocity.x = 0;
			FlxTween.tween(pessy, {y: 10}, 0.65, {ease: FlxEase.quadOut});
		}
		#end
	}

	#if HSCRIPT_ALLOWED
	override function destroy()
	{
		if(hscript != null)
		{
			if(hscript.exists('onDestroy')) hscript.call('onDestroy');
			hscript.destroy();
		}
		hscript = null;
		super.destroy();
	}
	#end
	
	var finishedLoading:Bool = false;
	function onLoad()
	{
		_loaded();

		if (stopMusic && FlxG.sound.music != null)
			FlxG.sound.music.stop();

		FlxG.camera.visible = false;
		MusicBeatState.switchState(target);
		transitioning = true;
		finishedLoading = true;
	}

	// ------------------------------------------------------------------
	// Operation lifecycle
	// ------------------------------------------------------------------

	static function createPool():FixedThreadPool
	{
		#if MULTITHREADED_LOADING
		// Due to the Main thread and Discord thread, we decrease it by 2.
		var threadCount:Int = Std.int(Math.max(1, getCPUThreadsCount() - #if DISCORD_ALLOWED 2 #else 1 #end));
		#else
		var threadCount:Int = 1;
		#end
		return new FixedThreadPool(threadCount);
	}

	static function shutdownPool()
	{
		var pool:FixedThreadPool = threadPool;
		threadPool = null;
		if (pool != null)
		{
			try { pool.shutdown(); }
			catch (e:Dynamic) { trace('WARNING: pool shutdown failed: $e'); }
		}
	}

	/** Invalidates every task of the running operation, stops workers, drops pending data. */
	static function cancelOperation()
	{
		generation++; // stragglers see a different generation and discard their results
		shutdownPool();

		lock.acquire();
		requestedBitmaps.clear();
		originalBitmapKeys.clear();
		requestedSounds.clear();
		loaded = 0;
		loadMax = 0;
		lock.release();

		commitBitmaps = [];
		commitSounds = [];
		deadline = 0;
	}

	static function _loaded()
	{
		cancelOperation();
		initialThreadCompleted = true;
		isIntrusive = false;
		FlxTransitionableState.skipNextTransIn = true;
	}

	static function fail(what:String, e:Dynamic)
	{
		var msg:String = '$what: $e';
		trace('ERROR! $msg');
		lock.acquire();
		errors.push(msg);
		lock.release();
	}

	/** Main thread. Registers decoded assets, spends at most COMMIT_BUDGET seconds on texture work per call. */
	public static function checkLoaded():Bool
	{
		lock.acquire();
		for (file => bitmap in requestedBitmaps)
			commitBitmaps.push({file: file, key: originalBitmapKeys.get(file), bitmap: bitmap});
		requestedBitmaps.clear();
		originalBitmapKeys.clear();
		for (file => snd in requestedSounds)
			commitSounds.push({file: file, sound: snd});
		requestedSounds.clear();
		var workDone:Bool = initialThreadCompleted && loaded >= loadMax;
		lock.release();

		for (p in commitSounds)
		{
			if (p.sound != null) Paths.currentTrackedSounds.set(p.file, p.sound);
			Paths.localTrackedAssets.push(p.file);
		}
		commitSounds = [];

		var start:Float = haxe.Timer.stamp();
		while (commitBitmaps.length > 0)
		{
			var p:PendingBitmap = commitBitmaps.shift();
			if (p.bitmap == null || Paths.cacheBitmap(p.key, null, p.bitmap) == null)
				fail('cache image ${p.key}', 'cacheBitmap failed');
			if (haxe.Timer.stamp() - start > COMMIT_BUDGET) break;
		}

		var done:Bool = workDone && commitBitmaps.length == 0;
		if (!done && deadline > 0 && Sys.time() > deadline)
		{
			fail('loading', 'timed out after ${LOAD_TIMEOUT}s, continuing with lazy loading');
			done = true;
		}
		return done;
	}

	public static function loadNextDirectory()
	{
		var directory:String = 'shared';
		var weekDir:String = StageData.forceNextDirectory;
		StageData.forceNextDirectory = null;

		if (weekDir != null && weekDir.length > 0 && weekDir != '') directory = weekDir;

		Paths.setCurrentLevel(directory);
		trace('Setting asset folder to ' + directory);
	}

	static var isIntrusive:Bool = false;
	static function getNextState(target:FlxState, stopMusic = false, intrusive:Bool = true):FlxState
	{
		#if !SHOW_LOADING_SCREEN
		intrusive = false;
		#end

		LoadingState.isIntrusive = intrusive;
		// C16: prepareToSong() already applied the level before resolving any path
		if (!levelApplied) loadNextDirectory();
		levelApplied = false;

		if(intrusive)
			return new LoadingState(target, stopMusic);
		
		if (stopMusic && FlxG.sound.music != null)
			FlxG.sound.music.stop();

		while(true)
		{
			if(checkLoaded())
			{
				_loaded();
				break;
			}
			else Sys.sleep(0.001);
		}
		return target;
	}

	static var imagesToPrepare:Array<String> = [];
	static var soundsToPrepare:Array<String> = [];
	static var musicToPrepare:Array<String> = [];
	static var songsToPrepare:Array<String> = [];
	public static function prepare(images:Array<String> = null, sounds:Array<String> = null, music:Array<String> = null)
	{
		if (images != null) imagesToPrepare = imagesToPrepare.concat(images);
		if (sounds != null) soundsToPrepare = soundsToPrepare.concat(sounds);
		if (music != null) musicToPrepare = musicToPrepare.concat(music);
	}

	static var initialThreadCompleted:Bool = true;

	// ------------------------------------------------------------------
	// Preparation (manifest) + scheduling
	// ------------------------------------------------------------------

	public static function prepareToSong()
	{
		cancelOperation();
		imagesToPrepare = [];
		soundsToPrepare = [];
		musicToPrepare = [];
		songsToPrepare = [];
		lock.acquire();
		errors = [];
		lock.release();

		if(PlayState.SONG == null)
		{
			initialThreadCompleted = true;
			isIntrusive = false;
			return;
		}

		// C16: the asset level must be known before any path is resolved
		loadNextDirectory();
		levelApplied = true;

		var gen:Int = generation;
		initialThreadCompleted = false;
		deadline = Sys.time() + LOAD_TIMEOUT;

		// Snapshots are taken on the main thread; workers never touch Paths' live maps.
		knownImages = [for (k in Paths.currentTrackedAssets.keys()) k => true];
		knownSounds = [for (k in Paths.currentTrackedSounds.keys()) k => true];

		var song:SwagSong = PlayState.SONG;
		var folder:String = Paths.formatToSongPath(Song.loadedSongName);

		var pool:FixedThreadPool = createPool();
		threadPool = pool; // ONE pool for this whole operation
		try
		{
			pool.run(() -> {
				try { prepareJob(gen, pool, song, folder); }
				catch (e:Dynamic)
				{
					fail('prepare song', e);
					finishEmpty(gen);
				}
			});
		}
		catch (e:Dynamic)
		{
			fail('start pool', e);
			finishEmpty(gen);
		}
	}

	/** Failure fallback: nothing to wait for, normal lazy loading takes over. */
	static function finishEmpty(gen:Int)
	{
		lock.acquire();
		if (gen == generation) { loadMax = 0; loaded = 0; }
		lock.release();
		if (gen == generation) initialThreadCompleted = true;
	}

	static function collectFromFilters(source:Dynamic, plan:PreloadPlan)
	{
		if (source == null) return;
		for (asset in Reflect.fields(source))
		{
			var filters:Int = Reflect.field(source, asset);
			var name:String = asset.trim();

			if(filters < 0 || StageData.validateVisibility(filters))
			{
				if(name.startsWith('images/'))
					plan.images.push(name.substr('images/'.length));
				else if(name.startsWith('sounds/'))
					plan.sounds.push(name.substr('sounds/'.length));
				else if(name.startsWith('music/'))
					plan.music.push(name.substr('music/'.length));
			}
		}
	}

	/** Runs on a pool thread. Builds the plan into local arrays (no shared mutation), then schedules. */
	static function prepareJob(gen:Int, pool:FixedThreadPool, song:SwagSong, folder:String)
	{
		var plan:PreloadPlan = new PreloadPlan();

		// LOAD NOTE IMAGE
		var noteSkin:String = Note.defaultNoteSkin;
		if(song.arrowSkin != null && song.arrowSkin.length > 1) noteSkin = song.arrowSkin;

		var customSkin:String = noteSkin + Note.getNoteSkinPostfix();
		if(Paths.fileExists('images/$customSkin.png', IMAGE)) noteSkin = customSkin;
		plan.images.push(noteSkin);

		// LOAD NOTE SPLASH IMAGE
		var noteSplash:String = NoteSplash.defaultNoteSplash;
		if(song.splashSkin != null && song.splashSkin.length > 0) noteSplash = song.splashSkin;
		else noteSplash += NoteSplash.getSplashSkinPostfix();
		plan.images.push(noteSplash);

		try
		{
			var path:String = Paths.json('$folder/preload');
			var json:Dynamic = null;

			#if MODS_FOR_DESKTOP
			var moddyFile:String = Paths.modsJson('$folder/preload');
			if (mobile.Utils.exists(moddyFile)) json = Json.parse(mobile.Utils.getContent(moddyFile));
			else json = Json.parse(mobile.Utils.getContent(path));
			#else
			json = Json.parse(Assets.getText(path));
			#end

			collectFromFilters(json, plan);
		}
		catch(e:Dynamic) {} // preload.json is optional

		if (song.stage == null || song.stage.length < 1)
			song.stage = StageData.vanillaSongStage(folder);

		var stageData:StageFile = StageData.getStageFile(song.stage);
		if (stageData != null)
		{
			collectFromFilters(stageData.preload, plan);

			if (stageData.objects != null)
			{
				for (sprite in stageData.objects)
				{
					if(sprite.type == 'sprite' || sprite.type == 'animatedSprite')
						if((sprite.filters < 0 || StageData.validateVisibility(sprite.filters)) && !plan.images.contains(sprite.image))
							plan.images.push(sprite.image);
				}
			}
		}

		plan.songs.push('$folder/Inst');

		var player1:String = song.player1;
		var player2:String = song.player2;
		var gfVersion:String = song.gfVersion;
		var prefixVocals:String = song.needsVoices ? '$folder/Voices' : null;
		if (gfVersion == null) gfVersion = 'gf';

		preloadCharacter(player1, prefixVocals, player1, plan);
		if (!plan.dontPreloadDefaultVoices && prefixVocals != null)
		{
			if(Paths.fileExists('$prefixVocals-Player.${Paths.SOUND_EXT}', SOUND, false, 'songs') && Paths.fileExists('$prefixVocals-Opponent.${Paths.SOUND_EXT}', SOUND, false, 'songs'))
			{
				plan.songs.push('$prefixVocals-Player');
				plan.songs.push('$prefixVocals-Opponent');
			}
			else if(Paths.fileExists('$prefixVocals.${Paths.SOUND_EXT}', SOUND, false, 'songs'))
				plan.songs.push(prefixVocals);
		}

		if (player2 != player1)
			preloadCharacter(player2, prefixVocals, player1, plan);
		if (stageData != null && !stageData.hide_girlfriend && gfVersion != player2 && gfVersion != player1)
			preloadCharacter(gfVersion, null, player1, plan);

		// publish the plan (single writer, still under the lock)
		lock.acquire();
		if (gen != generation) { lock.release(); return; }
		imagesToPrepare = plan.images.concat(imagesToPrepare);
		soundsToPrepare = plan.sounds.concat(soundsToPrepare);
		musicToPrepare = plan.music.concat(musicToPrepare);
		songsToPrepare = plan.songs.concat(songsToPrepare);
		lock.release();

		clearInvalids();
		scheduleAll(gen, pool); // exactly once per operation
	}

	public static function clearInvalids()
	{
		clearInvalidFrom(imagesToPrepare, 'images', '.png', IMAGE);
		clearInvalidFrom(soundsToPrepare, 'sounds', '.${Paths.SOUND_EXT}', SOUND);
		clearInvalidFrom(musicToPrepare, 'music', '.${Paths.SOUND_EXT}', SOUND); // C7: no leading space
		clearInvalidFrom(songsToPrepare, 'songs', '.${Paths.SOUND_EXT}', SOUND, 'songs');

		for (arr in [imagesToPrepare, soundsToPrepare, musicToPrepare, songsToPrepare])
			while (arr.contains(null))
				arr.remove(null);
	}

	static function addFolderEntry(arr:Array<String>, nam:String, relative:String, ext:String)
	{
		if (!relative.endsWith(ext)) return;
		var toAdd:String = nam + haxe.io.Path.withoutExtension(relative);
		if (!arr.contains(toAdd)) arr.push(toAdd);
	}

	static function clearInvalidFrom(arr:Array<String>, prefix:String, ext:String, type:AssetType, ?parentFolder:String = null)
	{
		var allAssets:Array<String> = null;
		for (folder in arr.copy())
		{
			var nam:String = folder.trim();
			if(nam.endsWith('/'))
			{
				// C8: mobile.Utils.readDirectory() returns FULL asset ids, not bare file names.
				for (subfolder in Mods.directoriesWithFile(Paths.getSharedPath(), '$prefix/$nam'))
				{
					for (file in mobile.Utils.readDirectory(subfolder))
						addFolderEntry(arr, nam, file.startsWith(subfolder) ? file.substr(subfolder.length) : file, ext);
				}

				// Folders bundled as assets are not directories for Assets.exists(): scan the manifest.
				if (allAssets == null) allAssets = OpenFlAssets.list();
				var roots:Array<String> = [Paths.getSharedPath()];
				if (Paths.currentLevel != null && Paths.currentLevel != 'shared')
					roots.push(Paths.getFolderPath('', Paths.currentLevel));
				for (root in roots)
				{
					var base:String = root + '$prefix/$nam';
					for (id in allAssets)
					{
						if (id != null && id.startsWith(base))
						{
							var rel:String = id.substr(base.length);
							if (rel.indexOf('/') < 0) addFolderEntry(arr, nam, rel, ext);
						}
					}
				}
			}
		}

		var i:Int = 0;
		while(i < arr.length)
		{
			var member:String = arr[i];
			var myKey = '$prefix/$member$ext';
			if(parentFolder == 'songs') myKey = '$member$ext';

			var doTrace:Bool = false;
			if(member.endsWith('/') || (!Paths.fileExists(myKey, type, false, parentFolder) && (doTrace = true)))
			{
				arr.remove(member);
				if(doTrace) trace('Removed invalid $prefix: $member');
			}
			else i++;
		}
	}

	static function dedupe(arr:Array<String>):Array<String>
	{
		var seen:Map<String, Bool> = [];
		var out:Array<String> = [];
		for (a in arr)
		{
			if (a == null || seen.exists(a)) continue;
			seen.set(a, true);
			out.push(a);
		}
		return out;
	}

	/** Kept for API compatibility; schedules the current lists on the current pool. */
	public static function startThreads()
	{
		if (threadPool == null) threadPool = createPool();
		scheduleAll(generation, threadPool);
	}

	/** C2/C3/C5: the only place that schedules asset tasks. One pool, one count, one completion flag. */
	static function scheduleAll(gen:Int, pool:FixedThreadPool)
	{
		lock.acquire();
		if (gen != generation) { lock.release(); return; }
		var images:Array<String> = dedupe(imagesToPrepare);
		var sounds:Array<String> = dedupe(soundsToPrepare);
		var music:Array<String> = dedupe(musicToPrepare);
		var songs:Array<String> = dedupe(songsToPrepare);
		loadMax = images.length + sounds.length + music.length + songs.length;
		loaded = 0;
		lock.release();

		var scheduled:Int = 0;
		try
		{
			for (sound in sounds) { runTask(gen, pool, 'sound $sound', () -> preloadSound(gen, 'sounds/$sound')); scheduled++; }
			for (m in music) { runTask(gen, pool, 'music $m', () -> preloadSound(gen, 'music/$m')); scheduled++; }
			for (song in songs) { runTask(gen, pool, 'song $song', () -> preloadSound(gen, song, 'songs', true)); scheduled++; }
			for (image in images) { runTask(gen, pool, 'image $image', () -> preloadGraphic(gen, image)); scheduled++; }
		}
		catch (e:Dynamic)
		{
			fail('schedule tasks', e);
			lock.acquire();
			if (gen == generation) loadMax = scheduled; // never wait for tasks that were not queued
			lock.release();
		}

		if (gen == generation) initialThreadCompleted = true;
	}

	static function runTask(gen:Int, pool:FixedThreadPool, name:String, func:Void->Bool)
	{
		pool.run(() -> {
			var ok:Bool = false;
			try
			{
				if (gen == generation) ok = func();
				else ok = true; // cancelled operation: nothing to report
			}
			catch (e:Dynamic) { fail('preload $name', e); ok = true; }

			if (!ok && gen == generation) fail('preload $name', 'asset could not be loaded');

			lock.acquire();
			if (gen == generation) loaded++; // C5: protected increment
			lock.release();
		});
	}

	// ------------------------------------------------------------------
	// Worker-side loaders (no GPU, no Paths mutation)
	// ------------------------------------------------------------------

	static function preloadCharacter(char:String, prefixVocals:String, player1Name:String, plan:PreloadPlan)
	{
		try
		{
			var path:String = Paths.getPath('characters/$char.json', TEXT);
			#if MODS_FOR_DESKTOP
			var character:Dynamic = Json.parse(mobile.Utils.getContent(path));
			#else
			var character:Dynamic = Json.parse(Assets.getText(path));
			#end

			var isAnimateAtlas:Bool = false;
			var img:String = character.image;
			img = img.trim();
			#if flxanimate
			var animToFind:String = Paths.getPath('images/$img/Animation.json', TEXT);
			if (#if MODS_FOR_DESKTOP mobile.Utils.exists(animToFind) || #end Assets.exists(animToFind))
				isAnimateAtlas = true;
			#end

			if(!isAnimateAtlas)
			{
				var split:Array<String> = img.split(',');
				for (file in split)
				{
					plan.images.push(file.trim());
				}
			}
			#if flxanimate
			else
			{
				for (i in 0...10)
				{
					var st:String = '$i';
					if(i == 0) st = '';
	
					if(Paths.fileExists('images/$img/spritemap$st.png', IMAGE))
					{
						plan.images.push('$img/spritemap$st');
						break;
					}
				}
			}
			#end
	
			if (prefixVocals != null && character.vocals_file != null && character.vocals_file.length > 0)
			{
				plan.songs.push(prefixVocals + "-" + character.vocals_file);
				if(char == player1Name) plan.dontPreloadDefaultVoices = true;
			}
		}
		catch(e:haxe.Exception)
		{
			fail('manifest character $char', e.details());
		}
	}

	// thread safe sound loader: decodes only, registration happens on the main thread (checkLoaded)
	static function preloadSound(gen:Int, key:String, ?path:String, ?modsAllowed:Bool = true):Bool
	{
		var file:String = Paths.getPath(Language.getFileTranslation(key) + '.${Paths.SOUND_EXT}', SOUND, path, modsAllowed);

		var sound:Sound = null;
		if (!knownSounds.exists(file))
		{
			if (#if sys FileSystem.exists(file) || #end OpenFlAssets.exists(file, SOUND))
			{
				sound = #if sys Sound.fromFile(file) #else OpenFlAssets.getSound(file, false) #end;
				if (sound == null) return false;
			}
			else return false;
		}

		lock.acquire();
		if (gen == generation) requestedSounds.set(file, sound); // null = already cached, only needs tracking
		lock.release();
		return true;
	}

	// thread safe image loader: decodes only, texture upload happens on the main thread
	static function preloadGraphic(gen:Int, key:String):Bool
	{
		var requestKey:String = 'images/$key';
		#if TRANSLATIONS_ALLOWED requestKey = Language.getFileTranslation(requestKey); #end
		if(requestKey.lastIndexOf('.') < 0) requestKey += '.png';

		if (knownImages.exists(requestKey)) return true;

		var file:String = Paths.getPath(requestKey, IMAGE);
		if (#if sys FileSystem.exists(file) || #end OpenFlAssets.exists(file, IMAGE))
		{
			#if sys
			var bitmap:BitmapData = BitmapData.fromFile(file);
			#else
			var bitmap:BitmapData = OpenFlAssets.getBitmapData(file, false);
			#end
			if (bitmap == null) return false;

			lock.acquire();
			if (gen == generation)
			{
				requestedBitmaps.set(file, bitmap);
				originalBitmapKeys.set(file, requestKey);
			}
			lock.release();
			return true;
		}
		trace('no such image $key exists');
		return false;
	}
	
	#if cpp
	@:functionCode('
		return std::thread::hardware_concurrency();
    	')
	@:noCompletion
    	public static function getCPUThreadsCount():Int
    	{
        	return -1;
    	}
    	#end
}

/** Plain data produced by the manifest step. Only ever touched by one thread. */
class PreloadPlan
{
	public var images:Array<String> = [];
	public var sounds:Array<String> = [];
	public var music:Array<String> = [];
	public var songs:Array<String> = [];
	public var dontPreloadDefaultVoices:Bool = false;

	public function new() {}
}

typedef PendingBitmap = {file:String, key:String, bitmap:BitmapData};
typedef PendingSound = {file:String, sound:Sound};
