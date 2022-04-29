/*
 * This file is part of Blokada.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright © 2021 Blocka AB. All rights reserved.
 *
 * @author Karol Gusak (karol@blocka.net)
 */

package ui.home

import android.content.Context
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.*
import model.Product
import org.blokada.R

class PaymentItemView : FrameLayout {

    constructor(context: Context) : super(context) {
        init(null, 0)
    }

    constructor(context: Context, attrs: AttributeSet) : super(context, attrs) {
        init(attrs, 0)
    }

    constructor(context: Context, attrs: AttributeSet, defStyle: Int) : super(context, attrs, defStyle) {
        init(attrs, defStyle)
    }

    var product: Product? = null
        set(value) {
            field = value
            product?.let { refresh(it) }
        }

    var onClick: (Product) -> Any = {}

    private fun init(attrs: AttributeSet?, defStyle: Int) {
        LayoutInflater.from(context).inflate(R.layout.item_payment, this, true)
    }

    private fun refresh(product: Product) {
        val group = findViewById<View>(R.id.payment_item_group)
        group.setOnClickListener {
            onClick(product)
        }
        group.setBackgroundResource(
            if (product.type == "cloud") R.drawable.bg_payment_item_cloud
            else R.drawable.bg_payment_item_plus
        )

        val header = findViewById<TextView>(R.id.payment_item_header)
        header.text = when {
            product.trial -> {
                context.getString(R.string.payment_plan_cta_trial)
            }
            product.periodMonths == 12 -> {
                context.getString(R.string.payment_plan_cta_annual)
            }
            else -> {
                // We do not support other packages now than yearly vs monthly
                context.getString(R.string.payment_plan_cta_monthly)
            }
        }

        val text = findViewById<TextView>(R.id.payment_item_text)
        text.text = when {
            product.trial -> {
                context.getString(
                    R.string.payment_subscription_per_year_then, product.price
                )
            }
            product.periodMonths == 12 -> {
                context.getString(
                    R.string.payment_subscription_per_year, product.price
                )
            }
            else -> {
                // We do not support other packages now than yearly vs monthly
                context.getString(
                    R.string.payment_subscription_per_month, product.price
                )
            }
        }

        // Shows additional per-month price for annual packages
        val info = findViewById<TextView>(R.id.payment_item_info)
        if (product.periodMonths == 12) {
            info.visibility = View.VISIBLE
            info.text = makeInfoText(product)
        } else {
            info.visibility = View.GONE
        }
    }

    private fun makeInfoText(p: Product): String {
        val price = p.pricePerMonth // TODO
        return if (p.type == "cloud") {
            "(%s)".format (
                context.getString(R.string.payment_subscription_per_month, price)
            )
        } else {
            "(%s. %s)".format(
                context.getString(R.string.payment_subscription_per_month, price),
                context.getString(R.string.payment_subscription_offer, "20%")
            )
        }
    }

}