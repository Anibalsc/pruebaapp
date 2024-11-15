// Your web app's Firebase configuration
const firebaseConfig = {
  apiKey: "AIzaSyBo1MItISgn_L-1Q9m7b4fht-vGLFyR-nw",
  authDomain: "pricebook-v2-be817.firebaseapp.com",
  databaseURL: "https://pricebook-v2-be817-default-rtdb.firebaseio.com",
  projectId: "pricebook-v2-be817",
  storageBucket: "pricebook-v2-be817.firebasestorage.app",
  messagingSenderId: "1039852695586",
  appId: "1:1039852695586:web:5362936365148dcddeda7b"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);

let map;
let products = [];

// Inicializar el mapa
function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            (position) => {
                const userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude
                };

                map = new google.maps.Map(document.getElementById("map"), {
                    center: userLocation,
                    zoom: 14
                });

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: "Tu ubicación"
                });
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("Geolocalización no es soportada por este navegador.");
    }
}

// Función para agregar un producto
function addProduct() {
    const productName = document.getElementById("productName").value;
    const productPrice = parseFloat(document.getElementById("productPrice").value);
    const storeLocation = document.getElementById("storeLocation").value;
    const productImage = document.getElementById("productImage").files[0];

    if (productName && !isNaN(productPrice) && storeLocation && productImage) {
        const productData = {
            name: productName,
            price: productPrice,
            store: storeLocation,
            image: URL.createObjectURL(productImage),
            location: map.getCenter(),
            timestamp: Date.now() // Se utiliza para ordenar por fecha
        };

        const productRef = db.ref('products').push();
        productRef.set(productData)
            .then(() => {
                alert("Producto agregado exitosamente.");
                loadRecentProducts(); // Actualiza la lista de productos
            })
            .catch((error) => {
                console.error("Error al guardar el producto:", error);
                alert("Hubo un problema al guardar el producto.");
            });
    } else {
        alert("Por favor, completa todos los campos.");
    }
}

// Función para cargar los productos más recientes
function loadRecentProducts() {
    const productList = document.getElementById("recentProducts");
    productList.innerHTML = ""; // Limpia la lista de productos antes de agregar nuevos

    db.ref('products')
        .orderByChild('timestamp')
        .limitToLast(5) // Muestra solo los 5 productos más recientes
        .once('value', (snapshot) => {
            snapshot.forEach((childSnapshot) => {
                const product = childSnapshot.val();

                const productItem = document.createElement("div");
                productItem.classList.add("product-item");
                productItem.innerHTML = `
                    <h4>${product.name}</h4>
                    <p>Precio: $${product.price}</p>
                    <p>Tienda: ${product.store}</p>
                    <p>Ubicación: ${product.location.lat}, ${product.location.lng}</p>
                `;
                productList.appendChild(productItem);
            });
        });
}

// Función para buscar el mejor precio
function searchBestPrice() {
    const searchProductName = document.getElementById("searchProductName").value.toLowerCase();

    db.ref('products')
        .once('value', (snapshot) => {
            let bestPrice = Infinity;
            let bestProduct = null;

            snapshot.forEach((childSnapshot) => {
                const product = childSnapshot.val();
                if (product.name.toLowerCase() === searchProductName && product.price < bestPrice) {
                    bestPrice = product.price;
                    bestProduct = product;
                }
            });

            if (bestProduct) {
                document.getElementById("bestStore").textContent = bestProduct.store;
                document.getElementById("bestPrice").textContent = bestPrice.toFixed(2);
                document.getElementById("bestLocation").textContent = `${bestProduct.location.lat}, ${bestProduct.location.lng}`;
                document.getElementById("recommendationBox").style.display = "block";
            } else {
                alert("Producto no encontrado.");
            }
        });
}
