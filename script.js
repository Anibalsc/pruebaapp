// Firebase Initialization
import { initializeApp } from "firebase/app";
import { getDatabase, ref, set, get, child } from "firebase/database";

// Configuración de Firebase
const firebaseConfig = {
  apiKey: "AIzaSyDSPfuNhHxO3ILg_BO2uK6jmiTQvxxdrss",
  authDomain: "comparador-de-precios-ae4b4.firebaseapp.com",
  databaseURL: "https://comparador-de-precios-ae4b4-default-rtdb.firebaseio.com",
  projectId: "comparador-de-precios-ae4b4",
  storageBucket: "comparador-de-precios-ae4b4.firebasestorage.app",
  messagingSenderId: "764983752712",
  appId: "1:764983752712:web:9ceed2bc4cf7f76adaf9bd",
  measurementId: "G-WC3YSRPJ3P"
};

const app = initializeApp(firebaseConfig);
const db = getDatabase(app);

// Mapa de Google y Geolocalización
let map;
let userLocation = { lat: 0, lng: 0 };

function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(function(position) {
            userLocation = {
                lat: position.coords.latitude,
                lng: position.coords.longitude
            };
            map = new google.maps.Map(document.getElementById("map"), {
                center: userLocation,
                zoom: 12
            });
            const marker = new google.maps.Marker({
                position: userLocation,
                map: map,
                title: "Tu ubicación"
            });
        });
    } else {
        alert("Geolocalización no soportada en este navegador.");
    }
}

// Función para almacenar productos en Firebase
document.getElementById("product-form").addEventListener("submit", function(e) {
    e.preventDefault();
    
    const productName = document.getElementById("product-name").value;
    const productPrice = document.getElementById("product-price").value;
    const storeName = document.getElementById("store-name").value;
    const productPhoto = document.getElementById("product-photo").files[0];
    
    // Guardamos el producto en la base de datos Firebase
    const newProductRef = ref(db, 'productos/' + Date.now());
    set(newProductRef, {
        name: productName,
        price: productPrice,
        store: storeName,
        location: userLocation,
        photo: productPhoto.name
    });

    alert("Producto guardado exitosamente.");

    // Lógica para comparar precios en la base de datos y mostrar el mejor precio
    comparePrices();
});

// Función para comparar precios
function comparePrices() {
    const productosRef = ref(db, 'productos/');
    get(productosRef).then((snapshot) => {
        if (snapshot.exists()) {
            let bestPrice = Infinity;
            let bestStore = "";
            snapshot.forEach((childSnapshot) => {
                const product = childSnapshot.val();
                if (parseFloat(product.price) < bestPrice) {
                    bestPrice = parseFloat(product.price);
                    bestStore = product.store;
                }
            });
            document.getElementById("best-price-box").style.display = "block";
            document.getElementById("best-store").textContent = bestStore;
            document.getElementById("best-price").textContent = `$${bestPrice}`;
        } else {
            console.log("No data available");
        }
    }).catch((error) => {
        console.error("Error: " + error);
    });
}
