package com.jasstudios.meltdown

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private val audio = MeltdownAudio()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "meltdown/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        audio.rate = (call.argument<Number>("rate") ?: 22050).toInt()
                        result.success(true)
                    }
                    "play" -> {
                        val pcm = call.argument<ByteArray>("pcm")
                        if (pcm == null) {
                            result.error("bad_args", "pcm missing", null)
                        } else {
                            audio.play(pcm)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        audio.shutdown()
        super.onDestroy()
    }
}

/**
 * Plays 16-bit mono PCM handed over from Dart.
 *
 * Every waveform in the game is synthesised in Dart, so the only job here is
 * to take a buffer and make a noise with it. Each sound gets its own short
 * lived AudioTrack, which is what lets short effects overlap rather than
 * queue behind one another.
 */
class MeltdownAudio {
    var rate: Int = 22050

    /** More overlap than this is inaudible, and the cap stops a stuck
     *  annunciator allocating tracks without limit. */
    private val maxVoices = 12
    private val live = AtomicInteger(0)

    // AudioTrack.write blocks, so it must not run on the platform thread.
    private val pool = Executors.newFixedThreadPool(4)

    fun play(pcm: ByteArray) {
        if (pcm.size < 2) return
        if (live.get() >= maxVoices) return
        live.incrementAndGet()
        try {
            pool.execute { render(pcm) }
        } catch (_: Throwable) {
            live.decrementAndGet()
        }
    }

    private fun render(pcm: ByteArray) {
        var track: AudioTrack? = null
        try {
            val min = AudioTrack.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val size = maxOf(min, pcm.size)
            track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        // GAME rather than MEDIA: it ducks politely and does
                        // not behave like a music player.
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(size)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()

            track.write(pcm, 0, pcm.size)
            track.play()
            // MODE_STATIC plays the whole buffer once; wait it out before
            // releasing, or the tail is cut off.
            val ms = (pcm.size / 2L) * 1000L / rate
            Thread.sleep(ms + 60)
        } catch (_: Throwable) {
            // A device that refuses the track is a silent sound, not a crash.
        } finally {
            try {
                track?.stop()
            } catch (_: Throwable) {
            }
            try {
                track?.release()
            } catch (_: Throwable) {
            }
            live.decrementAndGet()
        }
    }

    fun shutdown() {
        try {
            pool.shutdownNow()
        } catch (_: Throwable) {
        }
    }
}
