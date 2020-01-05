import Vue from 'vue'
import App from './App.vue'
import router from './router'
import BootstrapVue from 'bootstrap-vue'
import accounting from 'accounting'

Vue.use(BootstrapVue)

import 'bootstrap/dist/css/bootstrap.css'
import 'bootstrap-vue/dist/bootstrap-vue.css'

Vue.config.productionTip = false

new Vue({
  router,
  render: h => h(App)
}).$mount('#app')

Vue.filter('currency', function(val, ccy){
    if ( ccy === "GBP" ) {
        return accounting.formatMoney(val, "£ ", 2)
    } else if ( ccy === "DKK" ) {
        return accounting.formatMoney(val, "kr ", 2)
    } else if (ccy === "USD" ) {
        return accounting.formatMoney(val, "$ ", 2)
    } else if ( typeof ccy !== 'undefined' ) {
        return accounting.formatMoney(val, ccy + " ", 2)
    }
    return accounting.formatMoney(val, "", 2)
})
