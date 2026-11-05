# The Merger: one revenue number (reference dashboard)
#
# Fallback for the "Build the Dashboard" step. Paste this over the starter
# streamlit_app.py in a Workspace Streamlit app. It only uses packages that
# are pre-installed in the Streamlit container runtime.

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="The Merger: one revenue number", layout="wide")

conn = st.connection("snowflake")


@st.cache_data(ttl="10m")
def load_daily_revenue() -> pd.DataFrame:
    df = conn.query(
        """
        SELECT BUSINESS_DATE, STORE_ID, BRAND, CHANNEL, STORE_NAME, CITY,
               ORDER_COUNT, REVENUE_USD
        FROM MERGER_DB.ANALYTICS.DAILY_REVENUE
        """
    )
    df["BUSINESS_DATE"] = pd.to_datetime(df["BUSINESS_DATE"]).dt.date
    df["REVENUE_USD"] = df["REVENUE_USD"].astype(float)
    return df


st.title("Northbound + Daily Grind: one revenue number")
st.caption(
    "Merged in-store POS and web orders. Revenue in dollars, by each store's "
    "local business day, duplicates removed. Source: MERGER_DB.ANALYTICS.DAILY_REVENUE"
)

daily = load_daily_revenue()

min_date, max_date = daily["BUSINESS_DATE"].min(), daily["BUSINESS_DATE"].max()

with st.container(horizontal=True):
    date_range = st.date_input(
        "Business days",
        value=(min_date, max_date),
        min_value=min_date,
        max_value=max_date,
    )
    brands = st.pills(
        "Brand",
        options=sorted(daily["BRAND"].unique()),
        default=sorted(daily["BRAND"].unique()),
        selection_mode="multi",
    )

# date_input returns a single date while the user is mid-selection
if isinstance(date_range, tuple) and len(date_range) == 2:
    start, end = date_range
else:
    start = end = date_range if not isinstance(date_range, tuple) else date_range[0]

filtered = daily[
    (daily["BUSINESS_DATE"] >= start)
    & (daily["BUSINESS_DATE"] <= end)
    & (daily["BRAND"].isin(brands or []))
]

if filtered.empty:
    st.info("No orders match these filters.", icon=":material/filter_alt_off:")
    st.stop()

revenue = filtered["REVENUE_USD"].sum()
orders = int(filtered["ORDER_COUNT"].sum())

with st.container(horizontal=True):
    st.metric("Revenue", f"${revenue:,.2f}", border=True)
    st.metric("Orders", f"{orders:,}", border=True)
    st.metric("Average order", f"${revenue / orders:,.2f}", border=True)
    st.metric("Stores", filtered["STORE_ID"].nunique(), border=True)

with st.container(border=True):
    st.subheader("Daily revenue by brand")
    by_day = (
        filtered.groupby(["BUSINESS_DATE", "BRAND"], as_index=False)["REVENUE_USD"].sum()
    )
    chart = (
        alt.Chart(by_day)
        .mark_line(point=True)
        .encode(
            x=alt.X("BUSINESS_DATE:T", title="Business day"),
            y=alt.Y("REVENUE_USD:Q", title="Revenue (USD)"),
            color=alt.Color("BRAND:N", title="Brand"),
            tooltip=[
                alt.Tooltip("BUSINESS_DATE:T", title="Day"),
                alt.Tooltip("BRAND:N", title="Brand"),
                alt.Tooltip("REVENUE_USD:Q", title="Revenue", format="$,.2f"),
            ],
        )
    )
    st.altair_chart(chart)

left, right = st.columns(2)

with left:
    with st.container(border=True):
        st.subheader("Store leaderboard")
        leaderboard = (
            filtered.groupby(["STORE_NAME", "CITY", "BRAND"], as_index=False)
            .agg(REVENUE_USD=("REVENUE_USD", "sum"), ORDERS=("ORDER_COUNT", "sum"))
            .sort_values("REVENUE_USD", ascending=False)
        )
        st.dataframe(
            leaderboard,
            hide_index=True,
            column_config={
                "STORE_NAME": "Store",
                "CITY": "City",
                "BRAND": "Brand",
                "REVENUE_USD": st.column_config.NumberColumn("Revenue", format="dollar"),
                "ORDERS": st.column_config.NumberColumn("Orders"),
            },
        )

with right:
    with st.container(border=True):
        st.subheader("Revenue by channel")
        by_channel = filtered.groupby("CHANNEL", as_index=False)["REVENUE_USD"].sum()
        st.bar_chart(
            by_channel,
            x="CHANNEL",
            y="REVENUE_USD",
            x_label="Channel",
            y_label="Revenue (USD)",
        )
