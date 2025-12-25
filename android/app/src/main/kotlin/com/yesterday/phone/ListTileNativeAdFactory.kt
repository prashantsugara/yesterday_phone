package com.yesterday.phone

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

class ListTileNativeAdFactory(val context: Context) : GoogleMobileAdsPlugin.NativeAdFactory {

    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: MutableMap<String, Any>?
    ): NativeAdView {
        val nativeAdView = LayoutInflater.from(context)
            .inflate(R.layout.native_ad_layout, null) as NativeAdView

        // Icon
        val iconView = nativeAdView.findViewById<ImageView>(R.id.ad_app_icon)
        val icon = nativeAd.icon
        if (icon != null) {
            iconView.setImageDrawable(icon.drawable)
            iconView.visibility = View.VISIBLE
        } else {
            iconView.visibility = View.GONE
        }
        nativeAdView.iconView = iconView

        // Headline
        val headlineView = nativeAdView.findViewById<TextView>(R.id.ad_headline)
        headlineView.text = nativeAd.headline
        nativeAdView.headlineView = headlineView

        // Body
        val bodyView = nativeAdView.findViewById<TextView>(R.id.ad_body)
        with(bodyView) {
            text = nativeAd.body
            visibility = if (nativeAd.body?.isNotEmpty() == true) View.VISIBLE else View.INVISIBLE
        }
        nativeAdView.bodyView = bodyView

        // Call To Action (Button)
        val ctaView = nativeAdView.findViewById<Button>(R.id.ad_call_to_action)
        if (ctaView != null) {
            ctaView.text = nativeAd.callToAction
            ctaView.visibility = if (nativeAd.callToAction?.isNotEmpty() == true) View.VISIBLE else View.INVISIBLE
            nativeAdView.callToActionView = ctaView
        }

        nativeAdView.setNativeAd(nativeAd)

        return nativeAdView
    }
}
