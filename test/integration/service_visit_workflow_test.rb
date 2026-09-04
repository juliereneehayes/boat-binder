YªçŠx-®éÜj×¢ëiºÚ+Š§j[h‘éÜ¢éí÷İ¹N‹Z–‹­¦ëeŠw¬ÕÉ•ÅÕ¥É”€‰Ñ•ÍÑ}¡•±Á•Èˆ()±…ÍÌM•ÉÙ¥•Y¥Í¥Ñ]½É­™±½İQ•ÍĞ€ğÑ¥½¹¥ÍÁ…Ñ èé%¹Ñ•É…Ñ¥½¹Q•ÍĞ(€Í•ÑÕÀ‘¼(€€€Ñ¥½¹5…¥±•Èèé	…Í”¹‘•±¥Ù•É¥•Ì¹±•…È(€•¹((€Ñ•…É‘½İ¸‘¼(€€€Ñ¥½¹5…¥±•Èèé	…Í”¹‘•±¥Ù•É¥•Ì¹±•…È(€•¹((€Ñ•ÍĞ€‰…ÁÑ…¥¸Ù¥•İÌ…±°Í•ÉÙ¥”Ù¥Í¥ÑÌ™É½´‘…Í¡‰½…É…¹¹…Ù¥…Ñ¥½¸ˆ‘¼(€€€…ÁÑ…¥¸€ôÉ•‡ŞöæÚ$z{-®éÜj×tes: "Monitor charging profile.",
        active: "0"
      }
    }

    assert_redirected_to vessel_path(vessel, anchor: "batteries")
    battery.reload
    assert_equal "House Battery Bank", battery.name
    assert_equal "Aft lazarette", battery.location
    assert_not battery.active?
  end
end
