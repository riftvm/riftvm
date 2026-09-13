
        /VirGL performance: fps=/ {
            for (field_index = 1; field_index <= NF; field_index++) {
                field = $field_index
                gsub(/,$/, "", field)
                split(field, pair, "=")
                if (pair[1] == "timingVersion" && pair[2] == "2") timing_windows++
                if (pair[1] ~ /^(avgDrawableMs|p95DrawableMs|maxDrawableMs|avgFrameMs|p95FrameMs|maxFrameMs)$/) {
                    timing_count[pair[1]]++
                    timing_sum[pair[1]] += pair[2]
                    if (pair[2] > timing_max[pair[1]]) timing_max[pair[1]] = pair[2]
                }
                if (pair[1] == "fps") { fps += pair[2]; if (windows == 0 || pair[2] < min_fps) min_fps = pair[2] }
                if (pair[1] == "requested") requested += pair[2]
                if (pair[1] == "presented") presented += pair[2]
                if (pair[1] == "drawableMisses") misses += pair[2]
                if (pair[1] == "failures") failures += pair[2]
                if (pair[1] == "avgPresentMs") average_present += pair[2]
                if (pair[1] == "p95PresentMs" && pair[2] > maximum_p95_present) maximum_p95_present = pair[2]
                if (pair[1] == "maxPresentMs" && pair[2] > maximum_present) maximum_present = pair[2]
            }
            windows++
        }
        END {
            complete = windows > 0 && timing_windows == windows
            split("avgDrawableMs p95DrawableMs maxDrawableMs avgFrameMs p95FrameMs maxFrameMs", keys, " ")
            split("Average-Drawable-Ms Maximum-Window-P95-Drawable-Ms Maximum-Drawable-Ms Average-Frame-Ms Maximum-Window-P95-Frame-Ms Maximum-Frame-Ms", names, " ")
            for (i = 1; i <= 6; i++) if (timing_count[keys[i]] != windows) complete = 0
            printf "VirGL-Timing-Version: %s\n", complete ? "2" : (timing_windows > 0 ? "incomplete" : "1")
            for (i = 1; i <= 6; i++) {
                if (!complete) printf "VirGL-%s: unavailable\n", names[i]
                else printf "VirGL-%s: %.2f\n", names[i], (i == 1 || i == 4) ? timing_sum[keys[i]] / windows : timing_max[keys[i]]
            }
            printf "VirGL-Window-Count: %d\n", windows
            if (windows == 0) {
                print "VirGL-Average-FPS: unavailable"
                print "VirGL-Minimum-FPS: unavailable"
                print "VirGL-Requested-Frames: 0"
                print "VirGL-Presented-Frames: 0"
                print "VirGL-Drawable-Misses: 0"
                print "VirGL-Presentation-Failures: 0"
                print "VirGL-Average-Present-Ms: unavailable"
                print "VirGL-Maximum-Window-P95-Present-Ms: unavailable"
                print "VirGL-Maximum-Present-Ms: unavailable"
            } else {
                printf "VirGL-Average-FPS: %.1f\n", fps / windows
                printf "VirGL-Minimum-FPS: %.1f\n", min_fps
                printf "VirGL-Requested-Frames: %.0f\n", requested
                printf "VirGL-Presented-Frames: %.0f\n", presented
                printf "VirGL-Drawable-Misses: %.0f\n", misses
                printf "VirGL-Presentation-Failures: %.0f\n", failures
                printf "VirGL-Average-Present-Ms: %.2f\n", average_present / windows
                printf "VirGL-Maximum-Window-P95-Present-Ms: %.2f\n", maximum_p95_present
                printf "VirGL-Maximum-Present-Ms: %.2f\n", maximum_present
            }
        }
